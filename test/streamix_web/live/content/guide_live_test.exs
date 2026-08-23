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
      provider: provider,
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
      assert has_element?(view, "select[name='provider'] option[value='#{provider.id}']")
      assert has_element?(view, "[data-current-program='true']", "Jornal ao Vivo")
      assert has_element?(view, "a[href*='/watch/live_channel/#{channel.id}']", "Assistir")
    end

    test "filters by category and favorites without leaking other channels", %{
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
        category: "Esportes",
        start_time: DateTime.add(now, -5, :minute),
        end_time: DateTime.add(now, 60, :minute)
      })

      {:ok, view, _html} = live(conn, ~p"/guide")
      render_async(view)

      assert has_element?(view, "#guide-channel-#{channel.id}")
      assert has_element?(view, "#guide-channel-#{other.id}")

      view
      |> element("button[phx-value-category='Notícias']")
      |> render_click()

      render_async(view)
      assert has_element?(view, "#guide-channel-#{channel.id}")
      refute has_element?(view, "#guide-channel-#{other.id}")

      assert {:ok, :added} =
               Streamix.Iptv.toggle_favorite(user.id, "live_channel", channel.id, %{
                 content_name: channel.name,
                 content_icon: channel.stream_icon
               })

      {:ok, favorites_view, _html} = live(conn, ~p"/guide?favorites=true")
      render_async(favorites_view)

      assert has_element?(favorites_view, "#guide-channel-#{channel.id}")
      refute has_element?(favorites_view, "#guide-channel-#{other.id}")
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
  end
end
