defmodule Streamix.Gindex.Sync.SeriesTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Series
  alias Streamix.Iptv.Provider

  @provider %Provider{id: 42}
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
             Series.sync(@provider, @base_url, [@root_path],
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
             Series.sync(@provider, @base_url, [@root_path],
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
             Series.sync(@provider, @base_url, [@root_path],
               list_fun: fn _base_url, @root_path -> {:ok, folders(["a"])} end,
               scrape_fun: fn _base_url, _folder ->
                 {:ok, %{name: "A", episode_count: 1}}
               end,
               persist_fun: fn _provider, _series -> {:error, :database_unavailable} end,
               on_checkpoint: checkpoint_fun(parent)
             )

    refute_received {:checkpoint, _checkpoint}
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
