defmodule Streamix.Gindex.Sync.SeriesTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Series
  @source %{provider_id: 42}
  @base_url "https://gindex.example"
  @root_path "/1:/Series/"

  test "persists completed folders before pausing on quota exhaustion" do
    parent = self()
    folders = folders(~w(a b c))

    scrape_fun = fn _base_url, folder ->
      send(parent, {:scraped, folder.path})

      case folder.path do
        "/a/" -> {:ok, %{name: "A", episode_count: 2}}
        "/b/" -> {:error, {:quota_exhausted, 8_000}}
      end
    end

    assert {:error, {:quota_exhausted, 8_000}} =
             Series.sync(@source, @base_url, [@root_path],
               list_fun: fn _base_url, @root_path -> {:ok, folders} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:scraped, "/a/"}
    assert_received {:scraped, "/b/"}
    refute_received {:scraped, "/c/"}
    assert_received {:persisted, ["A"]}

    assert_received {:checkpoint, %{"root_path" => @root_path, "folder_path" => "/a/"}}
  end

  test "resumes after the last durably persisted folder" do
    parent = self()
    folders = folders(~w(c a b))

    scrape_fun = fn _base_url, folder ->
      send(parent, {:scraped, folder.path})

      case folder.path do
        "/b/" -> {:ok, %{name: "B", episode_count: 3}}
        "/c/" -> :empty
      end
    end

    checkpoint = %{"root_path" => @root_path, "folder_path" => "/a/"}

    assert {:ok, %{series_count: 1, episodes_count: 3}} =
             Series.sync(@source, @base_url, [@root_path],
               checkpoint: checkpoint,
               batch_size: 2,
               list_fun: fn _base_url, @root_path -> {:ok, folders} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    refute_received {:scraped, "/a/"}
    assert_received {:scraped, "/b/"}
    assert_received {:scraped, "/c/"}
    assert_received {:persisted, ["B"]}

    assert_received {:checkpoint, %{"root_path" => @root_path, "folder_path" => "/c/"}}
  end

  test "does not advance the checkpoint when persistence fails" do
    parent = self()

    assert {:error, :database_unavailable} =
             Series.sync(@source, @base_url, [@root_path],
               list_fun: fn _base_url, @root_path -> {:ok, folders(["a"])} end,
               scrape_fun: fn _base_url, _folder ->
                 {:ok, %{name: "A", episode_count: 1}}
               end,
               persist_fun: fn _provider, _series -> {:error, :database_unavailable} end,
               on_checkpoint: checkpoint_fun(parent)
             )

    refute_received {:checkpoint, _checkpoint}
  end

  test "records a truncated root listing as skipped instead of failing the root" do
    # Failing here paused the scan root with `retryable_error`, and a paused root
    # keeps its cycle active — so one unlistable root blocked every other root of
    # the provider from ever starting a new cycle.
    parent = self()
    folders = folders(~w(a b))
    partial_items = folders ++ [%{name: "README", path: "/README.txt", type: :file}]

    listing_error =
      {:partial_listing,
       %{
         items: partial_items,
         items_collected: 3,
         page: 1,
         reason: {:all_endpoints_failed, [%{reason: {:http_error, 500}}]}
       }}

    assert {:ok, %{series_count: 2, episodes_count: 2, skipped_count: 1}} =
             Series.sync(@source, @base_url, [@root_path],
               batch_size: 2,
               list_fun: fn _base_url, @root_path -> {:error, listing_error} end,
               scrape_fun: fn _base_url, folder ->
                 {:ok, %{name: folder.name, episode_count: 1}}
               end,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:persisted, ["A", "B"]}
    assert_received {:checkpoint, %{"root_path" => @root_path, "folder_path" => "/b/"}}
  end

  test "counts a truncated root listing once, and still reaches the refresh phase" do
    # Failing on the truncation skipped `continue_with_refresh/7` entirely, so the
    # cursor stayed pinned in `discover` and the refresh phase never ran again.
    # Now both phases run, and the one truncation must be charged once, not once
    # per phase.
    parent = self()
    folders = folders(~w(a b))
    known_paths = MapSet.new(["/a/"])

    listing_error =
      {:partial_listing, %{items: folders, items_collected: 2, page: 1}}

    scrape_fun = fn _base_url, folder ->
      send(parent, {:scraped, folder.path})
      {:ok, %{name: folder.name, episode_count: 1}}
    end

    assert {:ok, %{series_count: 2, episodes_count: 2, skipped_count: 1}} =
             Series.sync(@source, @base_url, [@root_path],
               strategy: :discovery_first,
               discovery_window: ~D[2026-08-10],
               known_paths: known_paths,
               batch_size: 1,
               list_fun: fn _base_url, @root_path -> {:error, listing_error} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    # "/b/" is unknown, so it belongs to the discover phase; "/a/" is known, so
    # only the refresh phase reaches it. Both arriving proves the truncation no
    # longer aborts the run between the two phases.
    assert_received {:scraped, "/b/"}
    assert_received {:scraped, "/a/"}

    assert_received {:checkpoint, %{"phase" => "refresh"}}
  end

  test "skips one broken folder without blocking the remaining catalog" do
    parent = self()

    scrape_fun = fn _base_url, folder ->
      case folder.path do
        "/b/" -> {:error, {:http_error, 500}}
        _path -> {:ok, %{name: folder.name, episode_count: 1}}
      end
    end

    assert {:ok, %{series_count: 2, episodes_count: 2, skipped_count: 1}} =
             Series.sync(@source, @base_url, [@root_path],
               batch_size: 1,
               list_fun: fn _base_url, @root_path -> {:ok, folders(~w(a b c))} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:persisted, ["A"]}
    assert_received {:checkpoint, %{"folder_path" => "/b/", "skipped_count" => 1}}
    assert_received {:persisted, ["C"]}
  end

  test "pauses instead of skipping a rate-limited folder" do
    parent = self()

    assert {:error, {:rate_limited, 429, 90}} =
             Series.sync(@source, @base_url, [@root_path],
               batch_size: 1,
               list_fun: fn _base_url, @root_path -> {:ok, folders(~w(a b c))} end,
               scrape_fun: fn _base_url, folder ->
                 if folder.path == "/b/",
                   do: {:error, {:rate_limited, 429, 90}},
                   else: {:ok, %{name: folder.name, episode_count: 1}}
               end,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:persisted, ["A"]}
    refute_received {:checkpoint, %{"folder_path" => "/b/"}}
    refute_received {:persisted, ["C"]}
  end

  test "discovers missing folders before resuming the legacy refresh cursor" do
    parent = self()
    folders = folders(~w(a b c d))
    known_paths = MapSet.new(["/a/", "/c/"])

    scrape_fun = fn _base_url, folder ->
      send(parent, {:scraped, folder.path})
      {:ok, %{name: folder.name, episode_count: 1}}
    end

    legacy_refresh_cursor = %{"root_path" => @root_path, "folder_path" => "/b/"}

    assert {:ok, %{series_count: 3, episodes_count: 3}} =
             Series.sync(@source, @base_url, [@root_path],
               checkpoint: legacy_refresh_cursor,
               strategy: :discovery_first,
               discovery_window: ~D[2026-08-10],
               known_paths: known_paths,
               batch_size: 1,
               list_fun: fn _base_url, @root_path -> {:ok, folders} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:scraped, "/b/"}
    assert_received {:scraped, "/d/"}
    assert_received {:scraped, "/c/"}
    refute_received {:scraped, "/a/"}

    assert_received {:persisted, ["B"]}
    assert_received {:persisted, ["D"]}
    assert_received {:persisted, ["C"]}

    assert_received {:checkpoint,
                     %{
                       "strategy" => "discovery_first_v1",
                       "phase" => "discover",
                       "discovery_window" => "2026-08-10",
                       "discovery" => %{"folder_path" => "/b/"},
                       "refresh" => ^legacy_refresh_cursor
                     }}

    assert_received {:checkpoint,
                     %{
                       "strategy" => "discovery_first_v1",
                       "phase" => "refresh",
                       "refresh" => %{"folder_path" => "/c/"}
                     }}
  end

  defp folders(names) do
    Enum.map(names, fn name -> %{name: String.upcase(name), path: "/#{name}/"} end)
  end

  defp persist_fun(parent) do
    fn _provider, series ->
      send(parent, {:persisted, Enum.map(series, & &1.name)})

      {:ok,
       %{
         series_count: length(series),
         episodes_count: Enum.sum(Enum.map(series, & &1.episode_count))
       }}
    end
  end

  defp checkpoint_fun(parent) do
    fn checkpoint ->
      send(parent, {:checkpoint, checkpoint})
      :ok
    end
  end
end
