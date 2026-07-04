defmodule StreamixWeb.HomePublicCatalogTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  describe "guest home" do
    test "renders the public catalog without requiring an account", %{conn: conn} do
      provider = global_provider_fixture(%{name: "Streamix Global"})

      movie_fixture(provider, %{
        name: "Public Movie",
        title: "Public Movie",
        stream_icon: "http://example.com/public-movie.jpg"
      })

      series_content_fixture(provider, %{
        name: "Public Series",
        title: "Public Series",
        cover: "http://example.com/public-series.jpg"
      })

      channel_fixture(provider, %{
        name: "Public Channel",
        stream_icon: "http://example.com/public-channel.png"
      })

      {:ok, view, _html} = live(conn, ~p"/")

      html = render(view)

      assert html =~ "Catálogo público"
      assert html =~ "Public Movie"
      assert html =~ "Public Series"
      assert html =~ "Public Channel"
      assert html =~ "Conta free"
      assert has_element?(view, "#public-stat-movies", "1")
      assert has_element?(view, "#public-stat-series", "1")
      assert has_element?(view, "#public-stat-channels", "1")
      refute html =~ "Reúna todos os seus provedores IPTV"
    end
  end
end
