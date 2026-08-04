defmodule StreamixWeb.Home.HeroTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Streamix.Iptv.Movie
  alias StreamixWeb.Home.Hero

  test "keeps the primary mobile actions at least 44px tall" do
    movie = %{
      id: 42,
      title: "Filme",
      name: "Filme",
      rating: nil,
      year: nil,
      genres: [],
      plot: nil
    }

    document =
      render_component(
        &Hero.hero_content/1,
        featured: {:movie, movie},
        current_scope: %{user: %{id: 7}},
        featured_favorite: false
      )
      |> Floki.parse_fragment!()

    assert has_class?(document, "a[href='/watch/movie/42']", "min-h-11")
    assert has_class?(document, "a[href='/browse/movies/42']", "min-h-11")

    assert has_class?(
             document,
             "button[phx-click='toggle_featured_favorite']",
             "size-11"
           )
  end

  test "keeps the desktop-only trailer mute control out of the mobile hit area" do
    movie = %Movie{id: 42, youtube_trailer: "trailer-id", assets: []}

    document =
      render_component(&Hero.hero_background/1, featured: {:movie, movie})
      |> Floki.parse_fragment!()

    assert has_class?(document, "#hero-mute-toggle", "hidden")
    assert has_class?(document, "#hero-mute-toggle", "md:flex")
    assert has_class?(document, "#hero-mute-toggle", "pointer-events-none")

    assert Floki.attribute(document, "#hero-mute-toggle", "aria-label") == [
             "Ativar som do trailer"
           ]
  end

  defp has_class?(document, selector, expected) do
    document
    |> Floki.find(selector)
    |> Floki.attribute("class")
    |> Enum.any?(fn classes -> expected in String.split(classes) end)
  end
end
