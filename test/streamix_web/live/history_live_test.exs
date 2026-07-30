defmodule StreamixWeb.HistoryLiveTest do
  @moduledoc """
  Tests for HistoryLive - user watch history management.

  Covers:
  - Mount with authenticated user
  - Infinite scroll pagination
  - Progress display
  - Empty state display
  """
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  describe "mount" do
    setup :register_and_log_in_user

    test "renders history page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/history")

      assert html =~ "Histórico"
      assert html =~ "Nenhum histórico"
      assert has_element?(view, "[data-sync-type='history']")
    end

    test "renders history when user has watch history", %{conn: conn, user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Canal Assistido"})
      _history = watch_history_fixture(user, channel, 3600)

      {:ok, _view, html} = live(conn, ~p"/history")

      assert html =~ "Canal Assistido"
      refute html =~ "Nenhum histórico"
    end

    test "displays filter buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/history")

      assert has_element?(view, "#history-filter-strip[data-filter-strip]")
      assert has_element?(view, "button", "Todos")
      assert has_element?(view, "button", "Ao Vivo")
      assert has_element?(view, "button", "Filmes")
      assert has_element?(view, "button", "Episódios")
    end
  end

  describe "infinite scroll" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})

      # Create 25 channels (more than page_size of 20)
      channels =
        for i <- 1..25 do
          channel_fixture(provider, %{name: "Canal #{String.pad_leading("#{i}", 2, "0")}"})
        end

      # Add all to watch history
      Enum.each(channels, &watch_history_fixture(user, &1, 1800))

      %{provider: provider}
    end

    test "loads initial page of history", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/history")

      # Should have 20 items initially (page_size)
      assert has_element?(view, "#history-list > div:nth-child(20)")
      refute has_element?(view, "#history-list > div:nth-child(21)")

      # Sentinel should be visible
      assert has_element?(view, "#history-sentinel")
    end

    test "loads more history on load_more event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/history")

      # Trigger load_more
      view |> render_hook("load_more", %{})

      # Should now have all 25 items
      assert has_element?(view, "#history-list > div:nth-child(25)")

      # Sentinel should be hidden (end of list)
      refute has_element?(view, "#history-sentinel")
    end

    test "does not load more when already loading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/history")

      # Trigger load_more twice rapidly - second should be ignored due to loading state
      view |> render_hook("load_more", %{})
      view |> render_hook("load_more", %{})

      # Should still have 25 items (not 45)
      assert has_element?(view, "#history-list > div:nth-child(25)")
      refute has_element?(view, "#history-list > div:nth-child(26)")
    end
  end

  describe "progress display" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})

      movie =
        movie_fixture(provider, %{
          name: "Filme com Progresso",
          title: "Filme com Progresso"
        })

      # 50% progress
      movie_history_fixture(user, movie, %{
        duration_seconds: 7200,
        progress_seconds: 3600
      })

      %{provider: provider}
    end

    test "displays progress indicator for partially watched content", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/history")

      assert html =~ "Filme com Progresso"
      # Progress bar should be at 50%
      assert html =~ "width: 50%"
      assert has_element?(view, "#history-list.responsive-wide-grid")
      assert has_element?(view, "#history-list [data-media-primary][phx-click='play']")

      assert has_element?(
               view,
               "#history-list [data-media-secondary] button[aria-label='Remover do histórico'].size-11"
             )

      refute has_element?(view, "#history-list [data-media-primary] button")
    end
  end

  describe "navigation" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Canal Navegavel"})
      watch_history_fixture(user, channel, 1800)

      %{provider: provider, channel: channel}
    end

    test "navigates to content on play click", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/history")

      # Click play on the history entry (first matching element with relative wrapper)
      view
      |> element(
        "[data-media-primary][phx-click='play'][phx-value-id='#{channel.id}'][phx-value-type='live_channel']"
      )
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
      watch_history_fixture(user, channel, 1800)

      {:ok, view, _html} = live(conn, ~p"/history")

      # OfflineSync hook should be present with data
      assert has_element?(view, "#history-sync[phx-hook='OfflineSync']")
      assert has_element?(view, "#history-sync[data-sync-type='history']")
    end
  end

  describe "relative time formatting" do
    setup :register_and_log_in_user

    setup %{user: user} do
      provider = provider_fixture(user, %{visibility: "global", is_system: true})
      channel = channel_fixture(provider, %{name: "Canal Recente"})
      watch_history_fixture(user, channel, 1800)

      %{provider: provider}
    end

    test "displays relative time for recent entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/history")

      # Should show "agora mesmo" or similar relative time
      assert html =~ "agora mesmo" or html =~ "min atrás"
    end
  end
end
