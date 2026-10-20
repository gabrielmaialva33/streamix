defmodule StreamixWeb.Content.DetailComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.DetailComponents
  alias StreamixWeb.Content.DetailComponents.{Actions, Badges}

  describe "Badges" do
    test "formats durations through the shared public helper" do
      assert Badges.format_duration(30) == "0min"
      assert Badges.format_duration(3_600) == "1h"
      assert Badges.format_duration(5_460) == "1h 31min"
      assert Badges.format_duration(nil) == nil
      assert DetailComponents.detail_format_duration(5_460) == "1h 31min"
    end

    test "renders numeric and decimal ratings" do
      assert render_component(&Badges.rating_badge/1, rating: 8.4) =~ "4.2"

      assert render_component(&Badges.rating_badge/1,
               rating: Decimal.new("8.4"),
               divide_by_two?: false
             ) =~ "8.4"

      refute render_component(&Badges.rating_badge/1, rating: nil) =~ "hero-star-solid"
    end

    test "maps content ratings to semantic color classes" do
      assert render_component(&Badges.content_rating_badge/1, rating: "L") =~
               "bg-success/10"

      assert render_component(&Badges.content_rating_badge/1, rating: "12") =~
               "bg-warning/10"

      assert render_component(&Badges.content_rating_badge/1, rating: "18") =~
               "bg-error/15"

      assert render_component(&Badges.content_rating_badge/1, rating: "NR") =~
               "bg-surface"
    end

    test "renders dates and aggregate episode counts" do
      assert render_component(&Badges.date_badge/1, date: ~D[2026-07-29]) =~ "29/07/2026"

      html =
        render_component(&Badges.series_count_badge/1,
          seasons: [%{episodes: [%{}, %{}]}, %{episodes: nil}]
        )

      assert html =~ "2 temp"
      assert html =~ "2 eps"
    end
  end

  describe "Actions" do
    test "renders accessible favorite state" do
      html = render_component(&Actions.favorite_button/1, favorite?: true)

      assert html =~ ~s(aria-label="Remover dos favoritos")
      assert html =~ "hero-heart-solid"
    end

    test "normalizes YouTube ids but preserves complete URLs" do
      id_html = render_component(&Actions.trailer_link/1, youtube_id: "abc123")
      url_html = render_component(&Actions.trailer_link/1, youtube_id: "https://youtu.be/abc123")

      assert id_html =~ "https://www.youtube.com/watch?v=abc123"
      assert url_html =~ "https://youtu.be/abc123"
      refute render_component(&Actions.trailer_link/1, youtube_id: nil) =~ "> Trailer"
    end

    test "builds the external TMDB target without leaking window ownership" do
      html = render_component(&Actions.tmdb_link/1, tmdb_id: 42, type: "movie")

      assert html =~ "https://www.themoviedb.org/movie/42"
      assert html =~ ~s(rel="noopener noreferrer")
    end
  end

  describe "detail_season_accordion and detail_episode_item" do
    test "formats episode titles as 'Piloto · T1 E1', renders still fallback chain, progress bar and completed check" do
      season = %{
        id: 10,
        season_number: 1,
        episodes: [
          %{
            id: 101,
            episode_num: 1,
            title: "Dawson's Creek - S01E01 - Piloto [LEG] 1080p",
            name: "Dawson.S01E01.mkv",
            still_path: "https://image.tmdb.org/t/p/w500/still1.jpg",
            cover: nil,
            plot: "O começo.",
            duration_secs: 2700
          },
          %{
            id: 102,
            episode_num: 2,
            title: "Dança",
            name: "Dawson.S01E02.mkv",
            still_path: nil,
            cover: nil,
            plot: nil,
            duration_secs: 2640
          },
          %{
            id: 103,
            episode_num: 3,
            title: nil,
            name: "Dawson.S01E03.1080p.WEB-DL.mkv",
            still_path: nil,
            cover: nil,
            plot: nil,
            duration_secs: nil
          }
        ]
      }

      html =
        render_component(&DetailComponents.detail_season_accordion/1,
          season: season,
          expanded: true,
          episode_paths: %{101 => "/ep/101", 102 => "/ep/102", 103 => "/ep/103"},
          episode_progress: %{101 => 0.95, 102 => 0.45},
          fallback_image: "https://image.tmdb.org/t/p/w780/series-backdrop.jpg"
        )

      # Cleaned episode titles with T1 E<n> code
      assert html =~ "Piloto · T1 E1"
      refute html =~ "Dawson&#39;s Creek - S01E01"
      assert html =~ "Dança · T1 E2"
      assert html =~ "Episódio 3 · T1 E3"

      # Ep 1 has its own still_path and is completed (>= 0.9)
      assert html =~ ~s(data-episode-still="episode")
      assert html =~ ~s(data-episode-completed)
      assert html =~ "Concluído"

      # Ep 2 has no still_path/cover, so it uses the series fallback with gradient and shows 45% progress bar
      assert html =~ ~s(data-episode-still="fallback")
      assert html =~ ~s(data-episode-progress)
      assert html =~ "width: 45%"
    end

    test "renders neutral placeholder when neither episode still nor series fallback exists" do
      html =
        render_component(&DetailComponents.detail_episode_item/1,
          episode: %{
            id: 201,
            episode_num: 4,
            title: "Capítulo Quatro",
            name: "Ep 4",
            still_path: nil,
            cover: nil,
            plot: nil,
            duration_secs: nil
          },
          season_number: 2,
          path: "/ep/201",
          progress: nil,
          fallback_image: nil
        )

      assert html =~ "Capítulo Quatro · T2 E4"
      assert html =~ ~s(data-episode-still="placeholder")
      refute html =~ ~s(data-episode-progress)
      refute html =~ ~s(data-episode-completed)
    end
  end
end
