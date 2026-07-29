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
end
