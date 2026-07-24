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
               provider,
               series_data(111, "/1:/Series/Example/S01/old.mkv"),
               now
             )

    original = Repo.one!(Episode)

    assert {:ok, 1} =
             Persistence.upsert_series_content(
               provider,
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
end
