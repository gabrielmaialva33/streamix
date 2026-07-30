defmodule StreamixWeb.HomePublicCatalogTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.Cache

  describe "guest home" do
    test "renders the public catalog without requiring an account", %{conn: conn} do
      provider = global_provider_fixture(%{name: "Streamix Global"})
      Cache.delete(Cache.public_stats_key())
      on_exit(fn -> Cache.delete(Cache.public_stats_key()) end)

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
      assert has_element?(view, "#landing-pwa-install[phx-hook='PwaInstall']")
      refute html =~ "Reúna todos os seus provedores IPTV"
    end

    test "refreshes stale public stats instead of showing the home rail limit", %{conn: conn} do
      provider = global_provider_fixture(%{name: "Streamix Global Totals"})

      Cache.set(
        Cache.public_stats_key(),
        %{movies_count: 0, series_count: 0, channels_count: 0},
        1_800
      )

      on_exit(fn -> Cache.delete(Cache.public_stats_key()) end)

      for index <- 1..14 do
        movie_fixture(provider, %{
          name: "Public Movie #{index}",
          title: "Public Movie #{index}",
          stream_icon: "http://example.com/public-movie-#{index}.jpg"
        })
      end

      for index <- 1..13 do
        series_content_fixture(provider, %{
          name: "Public Series #{index}",
          title: "Public Series #{index}",
          cover: "http://example.com/public-series-#{index}.jpg"
        })
      end

      for index <- 1..25 do
        channel_fixture(provider, %{
          name: "Public Channel #{index}",
          stream_icon: "http://example.com/public-channel-#{index}.png"
        })
      end

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#public-stat-movies", "14")
      assert has_element?(view, "#public-stat-series", "13")
      assert has_element?(view, "#public-stat-channels", "25")
      refute has_element?(view, "#public-stat-movies", "12")
      refute has_element?(view, "#public-stat-channels", "24")
    end

    test "renders the local fallback without requesting browser-blocked poster hosts", %{
      conn: conn
    } do
      provider = global_provider_fixture(%{name: "Streamix Global Images"})
      Cache.delete(Cache.public_stats_key())
      on_exit(fn -> Cache.delete(Cache.public_stats_key()) end)

      movie =
        movie_fixture(provider, %{
          name: "Blocked Poster Movie",
          title: "Blocked Poster Movie",
          stream_icon: "https://png.pngtree.com/thumb_back/fw800/background/20230616/pngtree.jpg"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      html = render(view)

      refute html =~ "png.pngtree.com"

      assert has_element?(
               view,
               "#public-movie-img-#{movie.id} [data-fallback]:not(.hidden)"
             )
    end
  end
end
