defmodule Streamix.Gindex.Sync.PersistenceTest do
  use Streamix.DataCase, async: true

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
