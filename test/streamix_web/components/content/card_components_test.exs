defmodule StreamixWeb.Content.CardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.CardComponents

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
