defmodule StreamixWeb.Content.CardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.CardComponents

  test "movie and series posters reserve a metadata line even without a year" do
    for {component, key} <- [
          {&CardComponents.movie_card/1, :movie},
          {&CardComponents.series_card/1, :series}
        ],
        year <- [nil, "", 2026] do
      document =
        component
        |> render_component([{key, %{id: 44, name: "Título", year: year}}])
        |> LazyHTML.from_fragment()

      metadata = LazyHTML.query(document, "[data-poster-metadata]")
      assert Enum.count(metadata) == 1

      assert LazyHTML.text(metadata) |> String.trim() ==
               if(year in [nil, ""], do: "", else: "2026")

      assert LazyHTML.attribute(metadata, "aria-hidden") ==
               if(year in [nil, ""], do: ["true"], else: [])

      [classes] = LazyHTML.attribute(metadata, "class")
      assert "min-h-[1em]" in String.split(classes)
      assert "sm:min-h-[1.5em]" in String.split(classes)
    end
  end

  test "movie card exposes one semantic primary action and a sibling favorite control" do
    html =
      render_component(&CardComponents.movie_card/1,
        movie: %{id: 42, name: "Filme", provider_id: 7}
      )

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "#movie-card-42 > [data-media-primary][type=button]") != []

    assert Floki.find(
             document,
             "#movie-card-42 > [data-media-secondary] button[aria-label='Adicionar aos favoritos']"
           ) != []

    assert Floki.find(document, "[data-media-primary] button") == []
  end

  test "landscape card renders navigation separately from its secondary action" do
    html =
      render_component(&CardComponents.landscape_media_card/1,
        id: "landscape-card",
        image_id: "landscape-image",
        title: "Episódio",
        content_id: 9,
        content_type: "episode",
        navigate: "/watch/episode/9",
        secondary_action: [
          %{
            inner_block: fn _assigns, _changed ->
              Phoenix.HTML.raw("<button type=\"button\">Remover</button>")
            end
          }
        ]
      )

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "#landscape-card > a[data-media-primary]") != []
    assert Floki.find(document, "#landscape-card > [data-media-secondary] > button") != []
    assert Floki.find(document, "a[data-media-primary] button") == []
  end

  test "limits hover-preview metadata in the initial card HTML" do
    prefix = String.duplicate("a", 240)
    plot = prefix <> "payload-that-must-not-ship"

    html =
      render_component(&CardComponents.movie_card/1,
        movie: %{
          id: 42,
          name: "Filme leve",
          plot: plot,
          provider_id: 7
        }
      )

    assert html =~ ~s(data-plot="#{prefix}")
    refute html =~ "payload-that-must-not-ship"
  end

  test "movie and series cards omit browser-blocked posters before render" do
    blocked_image = "https://static.vecteezy.com/system/resources/blocked-poster.png"

    movie_html =
      render_component(&CardComponents.movie_card/1,
        movie: %{
          id: 43,
          name: "Filme com fallback",
          stream_icon: blocked_image,
          provider_id: 7
        }
      )

    series_html =
      render_component(&CardComponents.series_card/1,
        series: %{id: 44, name: "Série com fallback", cover: blocked_image}
      )

    refute movie_html =~ "static.vecteezy.com"
    refute movie_html =~ "<img"
    refute series_html =~ "static.vecteezy.com"
    refute series_html =~ "<img"
  end
end
