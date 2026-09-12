defmodule Streamix.Iptv.Sync.EpisodeUpsertPreservationTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Iptv.Sync.Series.SeasonsEpisodes
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
        duration_secs: 3600,
        cover: "https://images.example.com/old.jpg",
        name: "Nome do episódio",
        still_path: "https://image.tmdb.org/p/w500/still.jpg",
        tmdb_enriched: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    %{series: series, season: season, now: now, catalog_item: catalog_item}
  end

  test "episode detail sync preserves shared enrichment when the provider sends blanks", %{
    series: series,
    season: season
  } do
    for blank <- [nil, ""] do
      assert {:ok, %{episodes: 1}} = SeasonsEpisodes.sync(series, episode_info(blank, blank))
      episode = Repo.one!(from(e in Episode, where: e.season_id == ^season.id))
      assert episode.episode_id == 2
      assert episode.title == "Título do provider"
      assert episode.cover == nil
      assert episode.container_extension == "mp4"
      assert episode.plot == "sinopse do TMDB"
      assert episode.duration_secs == 3600
      assert episode.name == "Nome do episódio"
      assert episode.still_path == "https://image.tmdb.org/p/w500/still.jpg"
      assert episode.tmdb_enriched
    end
  end

  test "episode detail sync fills missing metadata and accepts useful updates", %{
    series: series,
    season: season
  } do
    Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
      set: [plot: nil, duration_secs: nil]
    )

    for {plot, seconds} <- [{"Sinopse do provider", 1200}, {"Sinopse atualizada", 1500}] do
      assert {:ok, %{episodes: 1}} =
               SeasonsEpisodes.sync(series, episode_info(plot, to_string(seconds)))

      episode = Repo.one!(from(e in Episode, where: e.season_id == ^season.id))
      assert episode.plot == plot
      assert episode.duration_secs == seconds
    end
  end

  defp episode_info(plot, duration) do
    %{
      "info" => %{},
      "seasons" => [%{"season_number" => 1}],
      "episodes" => %{
        "1" => [
          %{
            "id" => "2",
            "episode_num" => 1,
            "title" => "Título do provider",
            "container_extension" => "mp4",
            "info" => %{"plot" => plot, "duration_secs" => duration}
          }
        ]
      }
    }
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
