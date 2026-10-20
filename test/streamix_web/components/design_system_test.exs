defmodule StreamixWeb.DesignSystemTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias StreamixWeb.App.Filters
  alias StreamixWeb.Content.CardComponents
  alias StreamixWeb.Content.DetailComponents.Actions
  alias StreamixWeb.Content.DetailComponents.Badges
  alias StreamixWeb.Content.HelperComponents, as: Helpers
  alias StreamixWeb.Content.NavigationComponents
  alias StreamixWeb.CoreComponents
  alias StreamixWeb.Home.Hero
  alias StreamixWeb.Home.Landing
  alias StreamixWeb.Layouts
  alias StreamixWeb.WatchPartyComponents

  test "Portuguese counts and relative times" do
    for {value, expected} <- [{nil, nil}, {999, "999"}, {1000, "1 mil"}, {76_100, "76,1 mil"}] do
      assert Helpers.format_count(value) == expected
    end

    now = ~U[2026-10-20 12:00:00Z]

    for {seconds, expected} <- [
          {0, "agora"},
          {300, "há 5 min"},
          {86_400, "ontem"},
          {259_200, "há 3 dias"}
        ] do
      assert Helpers.format_relative_time(DateTime.add(now, -seconds), now) == expected
    end
  end

  test "unknown ratings and years never render badges" do
    for rating <- [nil, 0, Decimal.new("0"), -1] do
      assert render_component(&Badges.rating_badge/1, rating: rating) |> String.trim() == ""
    end

    for year <- [nil, 0] do
      assert render_component(&Badges.year_badge/1, year: year) |> String.trim() == ""
    end
  end

  test "filter chips preserve events and expose their selected state" do
    html =
      render_component(&Filters.filter_chip/1,
        id: "test-chip",
        active: true,
        label: "Filmes",
        count: 76_100,
        rest: %{"phx-click" => "filter", "phx-value-type" => "movies"}
      )

    assert html =~ "76,1 mil"
    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(phx-click="filter")
  end

  test "all shared button variants and sizes keep events, links and touch targets" do
    for variant <- ~w(primary secondary ghost danger light), size <- ~w(sm md lg icon) do
      html =
        render_component(&CoreComponents.button/1,
          variant: variant,
          size: size,
          rest: %{type: "button", "phx-click": "play"},
          inner_block: [%{inner_block: fn _, _ -> "Assistir" end}]
        )

      assert html =~ "min-h-11"
      assert html =~ ~s(data-variant="#{variant}")
      assert html =~ ~s(data-size="#{size}")
      assert html =~ ~s(phx-click="play")
    end

    html =
      render_component(&CoreComponents.button/1,
        rest: %{navigate: "/browse"},
        inner_block: [%{inner_block: fn _, _ -> "Explorar" end}]
      )

    assert html =~ ~s(href="/browse")
    assert html =~ ~s(data-phx-link="redirect")
  end

  test "section headers share the action and IA label with styled selects" do
    html =
      render_component(&NavigationComponents.section_header/1,
        id: "test-section",
        title: "Destaques",
        ai_powered: true,
        see_more_path: "/browse",
        on_period_change: "period",
        period_filters: [{nil, "Todos"}, {7, "7 dias"}],
        selected_period: nil
      )

    assert html =~ "Ver todos"
    assert html =~ ">IA</span>"
    assert html =~ "appearance-none"
    assert html =~ ~s(value="all" selected)
  end

  test "title actions reserve primary for playback" do
    slot =
      render_component(&Actions.play_button/1,
        event: "play",
        label: "Assistir"
      )

    assert slot =~ ~s(data-variant="primary")

    party =
      render_component(&WatchPartyComponents.create_party_button/1,
        content_type: "movie",
        content_id: 42
      )

    assert party =~ ~s(data-variant="secondary")
    assert party =~ ~s(href="/party/new/movie/42")

    favorite =
      render_component(&Actions.favorite_button/1,
        favorite?: true
      )

    assert favorite =~ ~s(data-variant="ghost")
    assert favorite =~ ~s(aria-pressed="true")
  end

  test "home hero omits unknown metadata and preserves positive ratings" do
    movie = %{
      id: 42,
      title: "Filme",
      name: "Filme",
      rating: Decimal.new(0),
      year: 0,
      genres: [],
      plot: nil
    }

    html =
      render_component(&Hero.hero_content/1,
        featured: {:movie, movie},
        current_scope: nil,
        featured_favorite: false
      )

    refute html =~ ~s(data-badge="warning")
    assert html =~ "Detalhes"

    html =
      render_component(&Badges.rating_badge/1, rating: Decimal.new("8.5"), divide_by_two?: false)

    assert html =~ "8.5"
    assert html =~ ~s(data-badge="warning")
  end

  test "public and episode cards omit zero metadata" do
    item = %{id: 42, title: "Filme", name: "Filme", year: 0, rating: Decimal.new(0)}
    html = render_component(&Landing.public_media_card/1, item: item, kind: :movie)
    refute html =~ ">0</span>"
    refute html =~ "★ 0"

    html =
      render_component(&CardComponents.episode_card/1, episode: Map.put(item, :episode_num, 1))

    refute html =~ "hero-star-solid"
    refute html =~ ~s(data-badge="warning")
  end

  test "header transparency is limited to hero routes including query strings" do
    for path <- [
          "/",
          "/home?q=x",
          "/browse/movies/42",
          "/browse/series/1/episode/2",
          "/providers/1/series/42"
        ] do
      assert Layouts.hero_path?(path)
    end

    for path <- [nil, "/browse", "/browse/movies", "/search", "/watch/movie/42", "/settings"] do
      refute Layouts.hero_path?(path)
    end
  end
end
