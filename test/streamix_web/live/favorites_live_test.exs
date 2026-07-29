defmodule StreamixWeb.FavoritesLiveTest do
  @moduledoc """
  Tests for FavoritesLive - user favorites management.

  Covers:
  - Mount with authenticated user
  - Infinite scroll pagination
  - Empty state display
  """
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  describe "mount" do
    setup :register_and_log_in_user

    test "renders favorites page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/favorites")

      assert html =~ "Minha Lista"
      assert html =~ "Nenhum favorito"
      assert has_element?(view, "[data-sync-type='favorites']")
    end

    test "renders favorites when user has favorites", %{conn: conn, user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Canal Favorito"})
      _favorite = favorite_fixture(user, channel)

      {:ok, _view, html} = live(conn, ~p"/favorites")

      assert html =~ "Canal Favorito"
      refute html =~ "Nenhum favorito"
    end

    test "displays filter buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/favorites")

      assert has_element?(view, "button.min-h-11", "Todos")
      assert has_element?(view, "button", "Ao Vivo")
      assert has_element?(view, "button", "Filmes")
      assert has_element?(view, "button", "Séries")
      assert has_element?(view, "footer a[href='/'].min-w-11")
    end

    test "uses poster and wide artwork ratios according to content", %{conn: conn, user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})

      movie =
        movie_fixture(provider, %{
          name: "Filme Vertical",
          title: "Filme Vertical",
          stream_icon: "https://example.com/movie.jpg"
        })

      channel =
        channel_fixture(provider, %{
          name: "Canal Horizontal",
          stream_icon: "https://example.com/channel.png"
        })

      movie_favorite_fixture(user, movie)
      favorite_fixture(user, channel)

      {:ok, view, html} = live(conn, ~p"/favorites")

      assert has_element?(
               view,
               "[data-favorite-kind='poster'] [data-favorite-play] img.object-cover"
             )

      assert has_element?(
               view,
               "[data-favorite-kind='wide'] [data-favorite-play].aspect-video img.object-contain"
             )

      assert html =~ "aspect-[2/3]"
      assert has_element?(view, "button[aria-label='Remover dos favoritos'].size-11")
    end
  end

  describe "infinite scroll" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})

      # Create 30 channels (more than page_size of 24)
      channels =
        for i <- 1..30 do
          channel_fixture(provider, %{name: "Canal #{String.pad_leading("#{i}", 2, "0")}"})
        end

      # Add all as favorites
      Enum.each(channels, &favorite_fixture(user, &1))

      %{provider: provider}
    end

    test "loads initial page of favorites", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/favorites")

      # Should have 24 items initially (page_size)
      assert has_element?(view, "#favorites-grid > div:nth-child(24)")
      refute has_element?(view, "#favorites-grid > div:nth-child(25)")

      # Sentinel should be visible
      assert has_element?(view, "#favorites-sentinel")
    end

    test "loads more favorites on load_more event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/favorites")

      # Trigger load_more
      view |> render_hook("load_more", %{})

      # Should now have all 30 items
      assert has_element?(view, "#favorites-grid > div:nth-child(30)")

      # Sentinel should be hidden (end of list)
      refute has_element?(view, "#favorites-sentinel")
    end

    test "does not load more when already loading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/favorites")

      # Trigger load_more twice rapidly - second should be ignored due to loading state
      view |> render_hook("load_more", %{})
      view |> render_hook("load_more", %{})

      # Should still have 30 items (not 54)
      assert has_element?(view, "#favorites-grid > div:nth-child(30)")
      refute has_element?(view, "#favorites-grid > div:nth-child(31)")
    end
  end

  describe "navigation" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Canal Navegavel"})
      favorite_fixture(user, channel)

      %{provider: provider, channel: channel}
    end

    test "navigates to content on play click", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/favorites")

      # Click play on the favorite item (first matching element)
      view
      |> element("[data-favorite-play][phx-click='play'][phx-value-id='#{channel.id}']")
      |> render_click()

      # Should navigate to watch page
      assert_redirect(view, ~p"/watch/live_channel/#{channel.id}")
    end
  end

  describe "offline sync" do
    setup :register_and_log_in_user

    test "includes offline sync data in page", %{conn: conn, user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Sync Test"})
      favorite_fixture(user, channel)

      {:ok, view, _html} = live(conn, ~p"/favorites")

      # OfflineSync hook should be present with data
      assert has_element?(view, "#favorites-sync[phx-hook='OfflineSync']")
      assert has_element?(view, "#favorites-sync[data-sync-type='favorites']")
    end
  end
end
