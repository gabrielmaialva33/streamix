defmodule StreamixWeb.Content.GuideLiveTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "TV guide" do
    setup %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Provider Guia", visibility: :private})
      epg_channel_id = "guide-#{System.unique_integer([:positive])}"

      channel =
        channel_fixture(provider, %{
          name: "Canal Notícias",
          epg_channel_id: epg_channel_id,
          stream_icon: nil
        })

      now = DateTime.utc_now()

      current =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Jornal ao Vivo",
          description: "Notícias desta hora",
          category: "Notícias",
          start_time: DateTime.add(now, -15, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      next =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Entrevista da Tarde",
          category: "Entrevistas",
          start_time: DateTime.add(now, 30, :minute),
          end_time: DateTime.add(now, 90, :minute)
        })

      %{
        conn: log_in_user(conn, user),
        user: user,
        provider: provider,
        channel: channel,
        current: current,
        next: next
      }
    end

    test "renders now/next programs and provider-aware controls", %{
      conn: conn,
      channel: channel
    } do
      {:ok, view, html} = live(conn, ~p"/guide")
      assert html =~ "Guia de TV"
      assert html =~ "guide-loading"

      html = render_async(view)

      assert html =~ ~s(id="guide-channel-#{channel.id}")
      assert html =~ "Jornal ao Vivo"
      assert html =~ "Entrevista da Tarde"
      assert html =~ "Provider Guia"
      assert html =~ "Notícias"
      assert has_element?(view, "#guide-search-form input[name='search']")
      assert has_element?(view, "#guide-page-header")
      assert has_element?(view, ".guide-now-line[aria-hidden=true]")
      assert has_element?(view, "[data-guide-program][style*='--program-width']")
      assert has_element?(view, "#provider-dropdown button[role='option']", "Provider Guia")
      assert has_element?(view, "[data-current-program='true']", "Jornal ao Vivo")
      assert has_element?(view, "a[href*='/watch/live_channel/#{channel.id}']", "Assistir")
    end

    test "filters by category and favorites without leaking other channels and strips Canais | prefix",
         %{
           conn: conn,
           user: user,
           provider: provider,
           channel: channel
         } do
      other_epg_id = "guide-other-#{System.unique_integer([:positive])}"
      other = channel_fixture(provider, %{name: "Canal Esportes", epg_channel_id: other_epg_id})
      now = DateTime.utc_now()

      epg_program_fixture(provider, %{
        epg_channel_id: other_epg_id,
        title: "Futebol Agora",
        category: "Canais | Esportes",
        start_time: DateTime.add(now, -5, :minute),
        end_time: DateTime.add(now, 60, :minute)
      })

      {:ok, view, _initial_html} = live(conn, ~p"/guide")
      html = render_async(view)

      assert has_element?(view, "#guide-channel-#{channel.id}")
      assert has_element?(view, "#guide-channel-#{other.id}")
      assert has_element?(view, "button[phx-value-category='Esportes']", "Esportes")
      refute html =~ "Canais | Esportes"

      view
      |> element("button[phx-value-category='Notícias']")
      |> render_click()

      render_async(view)
      assert has_element?(view, "#guide-channel-#{channel.id}")
      refute has_element?(view, "#guide-channel-#{other.id}")

      assert {:ok, :added} =
               Streamix.Library.toggle_favorite(
                 library_key_fixture(user),
                 "live_channel",
                 channel.id,
                 %{
                   content_name: channel.name,
                   content_icon: channel.stream_icon
                 }
               )

      {:ok, favorites_view, _html} = live(conn, ~p"/guide?favorites=true")
      render_async(favorites_view)

      assert has_element?(favorites_view, "#guide-channel-#{channel.id}")
      refute has_element?(favorites_view, "#guide-channel-#{other.id}")

      render_click(favorites_view, "toggle_favorite", %{"id" => to_string(channel.id)})
      refute has_element?(favorites_view, "#guide-channel-#{channel.id}")

      render_click(favorites_view, "toggle_favorite", %{"id" => to_string(channel.id)})
      assert has_element?(favorites_view, "#guide-channel-#{channel.id}")
    end

    test "moves the timeline through bounded URL state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/guide")
      render_async(view)

      view
      |> element("button[phx-click='shift_window'][phx-value-direction='next']")
      |> render_click()

      patched_path = assert_patch(view)
      assert patched_path =~ "/guide?"
      assert patched_path =~ "at="

      view
      |> element("button[phx-click='go_now']")
      |> render_click()

      current_path = assert_patch(view)
      assert current_path =~ "/guide"
    end

    test "lists only channels with programming, in Brasília time", %{
      conn: conn,
      provider: provider,
      channel: channel,
      current: current
    } do
      silent = channel_fixture(provider, %{name: "Canal Sem Guia", epg_channel_id: nil})

      {:ok, view, _html} = live(conn, ~p"/guide")
      render_async(view)

      assert has_element?(view, "#guide-channel-#{channel.id}")
      refute has_element?(view, "#guide-channel-#{silent.id}")
      assert has_element?(view, "#guide-count", "1 canal com programação")
      assert has_element?(view, "#guide-window", "Hoje,")

      brasilia = current.start_time |> DateTime.add(-3, :hour) |> Calendar.strftime("%H:%M")
      assert has_element?(view, "[data-current-program='true']", brasilia <> "–")
    end

    test "one program on air and one row per channel across quality variants", %{
      conn: conn,
      provider: provider,
      channel: channel,
      current: current
    } do
      now = DateTime.utc_now()

      # A day-long umbrella entry on top of the real schedule.
      epg_program_fixture(provider, %{
        epg_channel_id: channel.epg_channel_id,
        title: "Maratona do Dia",
        start_time: DateTime.add(now, -10, :hour),
        end_time: DateTime.add(now, 10, :hour)
      })

      hd =
        channel_fixture(provider, %{
          name: "Canal Notícias HD",
          epg_channel_id: channel.epg_channel_id
        })

      regional =
        channel_fixture(provider, %{
          name: "Canal Notícias (RJ)",
          epg_channel_id: channel.epg_channel_id
        })

      {:ok, view, _html} = live(conn, ~p"/guide")
      render_async(view)

      refute render(view) =~ "Maratona do Dia"
      assert has_element?(view, "[data-current-program='true']", current.title)
      assert view |> render() |> String.split("data-current-program=\"true\"") |> length() == 3

      assert has_element?(view, "#guide-channel-#{channel.id}")
      refute has_element?(view, "#guide-channel-#{hd.id}")
      assert has_element?(view, "#guide-channel-#{regional.id}")
    end

    test "shows channels a page at a time, favorites and real schedules first", %{
      conn: conn,
      user: user,
      provider: provider,
      channel: channel
    } do
      now = DateTime.utc_now()

      channels =
        for n <- 1..34 do
          epg_id = "page-#{n}-#{System.unique_integer([:positive])}"
          name = "Canal #{String.pad_leading(Integer.to_string(n), 2, "0")}"
          channel = channel_fixture(provider, %{name: name, epg_channel_id: epg_id})

          # A placeholder: one program covering the whole window.
          epg_program_fixture(provider, %{
            epg_channel_id: epg_id,
            title: "Programação #{n}",
            start_time: DateTime.add(now, -6, :hour),
            end_time: DateTime.add(now, 6, :hour)
          })

          channel
        end

      favorite = List.last(channels)

      {:ok, :added} =
        Streamix.Library.toggle_favorite(
          library_key_fixture(user),
          "live_channel",
          favorite.id,
          %{content_name: favorite.name, content_icon: nil}
        )

      {:ok, view, _html} = live(conn, ~p"/guide")
      html = render_async(view)

      # 35 channels: the favorite, the one with a real schedule ("Canal
      # Notícias", two programs), then the placeholders by name.
      assert has_element?(view, "#guide-count", "35 canais com programação")
      rows = Regex.scan(~r/id="(guide-channel-\d+)"/, html) |> Enum.map(&List.last/1)
      assert length(rows) == 30

      assert Enum.take(rows, 3) == [
               "guide-channel-#{favorite.id}",
               "guide-channel-#{channel.id}",
               "guide-channel-#{hd(channels).id}"
             ]

      assert has_element?(view, "#guide-load-more", "(5)")

      view |> element("#guide-load-more") |> render_click()
      assert has_element?(view, "#guide-channel-#{Enum.at(channels, 32).id}")
      refute has_element?(view, "#guide-load-more")
    end
  end
end
