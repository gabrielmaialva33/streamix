defmodule StreamixWeb.Content.LiveChannelsPremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv

  describe "premium signals" do
    setup do
      user = user_fixture()

      global_provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      channel = channel_fixture(global_provider, %{name: "Canal Premium"})
      owned_provider = provider_fixture(user)

      %{
        user: user,
        global_provider: global_provider,
        owned_provider: owned_provider,
        channel: channel
      }
    end

    test "shows premium cta banner in browse mode", %{conn: conn, user: user, channel: channel} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse")

      assert has_element?(view, "#browse-premium-cta")
      assert render(view |> element("#browse-premium-cta a")) =~ ~s(href="/plans")
      assert has_element?(view, "#channel-img-#{channel.id}")
    end

    test "does not show premium cta banner in provider mode", %{
      conn: conn,
      user: user,
      owned_provider: owned_provider
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/providers/#{owned_provider.id}")

      refute has_element?(view, "#browse-premium-cta")
      refute has_element?(view, "#browse-premium-cta a[href=\"/plans\"]")
    end
  end

  describe "provider filter" do
    test "provider=all lists visible channels even when no global provider exists", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Live Catalog"})
      channel = channel_fixture(provider, %{name: "Private Live Channel"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse")

      assert has_element?(view, "#channel-img-#{channel.id}")
    end

    test "provider=all empty state works when no global provider exists", %{conn: conn} do
      user = user_fixture()
      _provider = provider_fixture(user, %{name: "Empty Live Catalog"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse")

      assert html =~ "Nenhum canal encontrado"
      refute has_element?(view, "#video-player-modal")
    end

    test "provider=all player uses the selected channel provider", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Live Catalog"})
      channel = channel_fixture(provider, %{name: "Private Live Channel"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse")

      html = render_hook(view, "play_channel", %{"id" => channel.id})

      assert html =~ ~s(id="video-player-modal")
      assert html =~ URI.encode_www_form(provider.url)
    end

    test "forged events cannot play or favorite another user's private channel", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      private_provider = provider_fixture(owner, %{name: "Other Private Catalog"})
      private_channel = channel_fixture(private_provider, %{name: "Other Private Channel"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/browse")

      play_html = render_hook(view, "play_channel", %{"id" => private_channel.id})
      favorite_html = render_hook(view, "toggle_favorite", %{"id" => private_channel.id})
      refresh_html = render_hook(view, "refresh_epg", %{"channel_ids" => [private_channel.id]})

      refute play_html =~ ~s(id="video-player-modal")
      refute favorite_html =~ ~s(id="channel-img-#{private_channel.id}")
      refute refresh_html =~ "Other Private Channel"
      refute Iptv.favorite?(user.id, "live_channel", private_channel.id)
    end
  end
end
