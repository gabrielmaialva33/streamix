defmodule Streamix.Gindex.Sync.PersistenceTest do
  # Not async: one case reconfigures the global Logger level.
  use Streamix.DataCase, async: false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Streamix.Gindex.Sync.Persistence
  alias Streamix.Iptv.{CatalogItem, Episode, Provider}
  alias Streamix.Repo

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Persistence Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    })
    |> Repo.insert!()
  end

  # Builds the same series with an arbitrary set of episodes, so a season can be
  # replayed with different numbers for the same files.
  defp series_with(episodes) do
    %{
      series_id: 10_001,
      name: "Example Series",
      title: "Example Series",
      year: 2026,
      gindex_path: "/1:/Series/Example Series/",
      seasons: [
        %{
          season_number: 1,
          name: "Season 1",
          episode_count: length(episodes),
          episodes:
            Enum.map(episodes, fn {episode_id, episode_num} ->
              %{
                episode_id: episode_id,
                episode_num: episode_num,
                title: "Episode #{episode_num}",
                name: "1x#{String.pad_leading(to_string(episode_num), 2, "0")} - Episode",
                container_extension: "mkv",
                gindex_path: "/1:/Series/Example/S01/#{episode_id}.mkv"
              }
            end)
        }
      ]
    }
  end

  defp sync(provider, data, now) do
    Persistence.upsert_series_content(%{provider_id: provider.id}, data, now)
  end

  defp episode_rows do
    Episode
    |> Repo.all()
    |> Enum.sort_by(& &1.episode_num)
    |> Enum.map(&{&1.episode_id, &1.episode_num})
  end

  defp series_data(episode_id, path) do
    %{
      series_id: 10_001,
      name: "Example Series",
      title: "Example Series",
      year: 2026,
      gindex_path: "/1:/Series/Example Series/",
      seasons: [
        %{
          season_number: 1,
          name: "Season 1",
          episode_count: 1,
          episodes: [
            %{
              episode_id: episode_id,
              episode_num: 1,
              title: "Pilot",
              name: "S01E01 - Pilot",
              container_extension: "mkv",
              gindex_path: path
            }
          ]
        }
      ]
    }
  end

  test "updates an episode whose path-derived id changed without violating episode_num" do
    provider = gindex_provider()
    now = ~U[2026-07-24 12:00:00Z]

    assert {:ok, 1} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               series_data(111, "/1:/Series/Example/S01/old.mkv"),
               now
             )

    original = Repo.one!(Episode)

    assert {:ok, 1} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               series_data(222, "/1:/Series/Example/S01/new.mkv"),
               DateTime.add(now, 60)
             )

    updated = Repo.one!(Episode)

    assert updated.id == original.id
    assert updated.catalog_item_id == original.catalog_item_id
    assert updated.episode_id == 222
    assert updated.episode_num == 1
    assert updated.gindex_path == "/1:/Series/Example/S01/new.mkv"

    assert Repo.aggregate(
             from(c in CatalogItem, where: c.content_type == "episode"),
             :count
           ) == 1
  end

  describe "episodes renumbered by a parser change" do
    # `episodes` has a unique index on (season_id, episode_num) and another on
    # (season_id, episode_id). Upserting only on the number treated a file whose
    # number changed as new, and the insert then collided with that file's own
    # row on the id index — in production the Postgrex unique_violation aborted
    # the batch and failed the scan root on every attempt.

    test "moves an existing file to its new number, keeping its row" do
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 12}]), now)
      original = Repo.one!(Episode)

      assert {:ok, 1} = sync(provider, series_with([{111, 6}]), DateTime.add(now, 60))

      updated = Repo.one!(Episode)
      assert updated.id == original.id
      assert updated.catalog_item_id == original.catalog_item_id
      assert updated.episode_id == 111
      assert updated.episode_num == 6
    end

    test "fills a season that had collapsed onto a single number" do
      # The production shape: every file in the folder scored the same number,
      # `Enum.uniq_by/2` kept one, and the season was left holding one row.
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 12}]), now)
      collapsed = Repo.one!(Episode)

      assert {:ok, 3} =
               sync(provider, series_with([{111, 6}, {222, 1}, {333, 2}]), DateTime.add(now, 60))

      assert episode_rows() == [{222, 1}, {333, 2}, {111, 6}]

      kept = Repo.get_by!(Episode, episode_id: 111)
      assert kept.id == collapsed.id
      assert kept.catalog_item_id == collapsed.catalog_item_id

      # The file that moved keeps its catalog item, so nothing else may be handed
      # the one it vacated — catalog_item_id is globally unique.
      catalog_item_ids = Episode |> Repo.all() |> Enum.map(& &1.catalog_item_id)
      assert length(Enum.uniq(catalog_item_ids)) == 3

      assert Repo.aggregate(from(c in CatalogItem, where: c.content_type == "episode"), :count) ==
               3
    end

    test "survives a season whose numbers merely permute" do
      # Without parking the rows first, Postgres checks the unique index row by
      # row and the swap collides with itself halfway through the statement.
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 2} = sync(provider, series_with([{111, 1}, {222, 2}]), now)
      before = Map.new(Repo.all(Episode), &{&1.episode_id, &1.id})

      assert {:ok, 2} = sync(provider, series_with([{111, 2}, {222, 1}]), DateTime.add(now, 60))

      assert episode_rows() == [{222, 1}, {111, 2}]

      after_swap = Map.new(Repo.all(Episode), &{&1.episode_id, &1.id})
      assert after_swap == before
    end

    test "leaves no parked negative numbers behind" do
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 2} = sync(provider, series_with([{111, 8}, {222, 9}]), now)
      assert {:ok, 2} = sync(provider, series_with([{111, 1}, {222, 2}]), DateTime.add(now, 60))

      assert Repo.aggregate(from(e in Episode, where: e.episode_num < 0), :count) == 0
    end
  end

  describe "a number reassigned from a file that is gone" do
    # The collision neither conflict target can resolve: a file that is still
    # in the listing moves onto a number held by a row whose own file is not.
    # Because the mover upserts on episode_id, the row in its way is never
    # visited and Postgres rejects the batch on (season_id, episode_num). In
    # production this left /0:/Animes/ `failed` and
    # /1:/Séries/Séries Misturado/ retrying for eleven days.

    test "drops the stale row and lets the surviving file take the number" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # The production shape, from /0:/Animes/Digimon Savers/: one file parsed
      # as 0 by the old digit-run fallback, another already holding 1.
      assert {:ok, 2} = sync(provider, series_with([{111, 0}, {222, 1}]), now)

      kept = Repo.get_by!(Episode, episode_id: 111)
      gone = Repo.get_by!(Episode, episode_id: 222)

      # Only the first file is still upstream, and it now parses as 1.
      assert {:ok, 1} = sync(provider, series_with([{111, 1}]), DateTime.add(now, 60))

      assert episode_rows() == [{111, 1}]

      moved = Repo.get_by!(Episode, episode_id: 111)
      assert moved.id == kept.id
      assert moved.catalog_item_id == kept.catalog_item_id
      refute Repo.get(Episode, gone.id)
    end

    test "still repurposes the row when a new file claims the number" do
      # Unchanged behaviour: when the claimant is a file the season has never
      # seen, (season_id, episode_num) is the conflict target and the row is
      # reused rather than dropped, so its catalog item survives.
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 1}]), now)
      original = Repo.one!(Episode)

      assert {:ok, 1} = sync(provider, series_with([{999, 1}]), DateTime.add(now, 60))

      reused = Repo.one!(Episode)
      assert reused.id == original.id
      assert reused.catalog_item_id == original.catalog_item_id
      assert reused.episode_id == 999
    end

    @tag :capture_log
    test "says which files it drops when two share a number" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # The suite runs the Logger at :warning, and this is reported at :info
      # precisely because it is an ordinary event rather than a fault.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 1} = sync(provider, series_with([{111, 7}, {222, 7}]), now)
        end)

      # Silence here is how the catalogue lost episodes without a trace.
      assert log =~ "collide on an episode number"
      assert episode_rows() == [{111, 7}]
    end
  end

  test "rolls back the catalog item when the series cannot be inserted" do
    provider = gindex_provider()
    invalid_data = %{series_data(111, "/1:/Series/Example/S01/pilot.mkv") | name: nil}

    assert {:error, %Ecto.InvalidChangesetError{}} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               invalid_data,
               ~U[2026-07-24 12:00:00Z]
             )

    assert Repo.aggregate(CatalogItem, :count) == 0
  end
end
