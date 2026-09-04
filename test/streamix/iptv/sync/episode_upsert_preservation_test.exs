defmodule Streamix.Iptv.Sync.EpisodeUpsertPreservationTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo

  # The xtream episode payload supplies only a handful of columns. Under
  # `:replace_all_except` the rest were written as `EXCLUDED.col` — the column
  # default — so every six-hour sync nulled `name`, `still_path`, `rating`,
  # `air_date`, `tmdb_id` and `tmdb_enriched`. Enrichment could not survive a
  # sync cycle. These tests pin the preservation, not the reasoning.
  setup do
    provider = global_provider_fixture(%{provider_type: :xtream})
    series = series_content_fixture(provider)

    season =
      Repo.insert!(%Season{series_id: series.id, season_number: 1, episode_count: 1})

    now = DateTime.utc_now(:second)
    catalog_item = catalog_item_fixture("episode", provider.id)

    Repo.insert_all(Episode, [
      %{
        episode_id: 1,
        episode_num: 1,
        season_id: season.id,
        catalog_item_id: catalog_item.id,
        plot: "sinopse do TMDB",
        name: "Nome do episódio",
        still_path: "https://image.tmdb.org/p/w500/still.jpg",
        tmdb_enriched: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    %{season: season, now: now, catalog_item: catalog_item}
  end

  test "a sync keeps every column its payload has no opinion about", %{
    season: season,
    now: now,
    catalog_item: catalog_item
  } do
    # Exactly the map `Sync.Series.SeasonsEpisodes.episode_attrs/3` builds.
    Repo.insert_all(
      Episode,
      [
        %{
          episode_id: 1,
          episode_num: 1,
          title: "Título do provider",
          plot: nil,
          cover: nil,
          duration_secs: nil,
          container_extension: "mp4",
          season_id: season.id,
          catalog_item_id: catalog_item.id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        {:replace, ~w(episode_id title plot cover duration_secs container_extension updated_at)a},
      conflict_target: [:season_id, :episode_num]
    )

    episode = Repo.one(from(e in Episode, where: e.season_id == ^season.id))

    # Columns the payload carries are replaced, including with an explicit nil.
    assert episode.title == "Título do provider"
    assert episode.plot == nil

    # Everything the payload omits is enrichment, and survives.
    assert episode.name == "Nome do episódio"
    assert episode.still_path == "https://image.tmdb.org/p/w500/still.jpg"
    assert episode.tmdb_enriched
  end

  test "the season upsert keeps the same contract", %{season: season, now: now} do
    Repo.update_all(from(s in Season, where: s.id == ^season.id),
      set: [tmdb_details_at: DateTime.utc_now(:second)]
    )

    Repo.insert_all(
      Season,
      [
        %{
          season_number: season.season_number,
          name: "Temporada 1",
          cover: nil,
          air_date: nil,
          overview: nil,
          episode_count: 12,
          series_id: season.series_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, ~w(name cover air_date overview episode_count updated_at)a},
      conflict_target: [:series_id, :season_number]
    )

    reloaded = Repo.get!(Season, season.id)

    assert reloaded.name == "Temporada 1"
    assert reloaded.episode_count == 12
    assert reloaded.tmdb_details_at, "the enrichment stamp was reset by a sync"
  end
end
