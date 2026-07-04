defmodule StreamixWeb.Content.LiveChannelsPremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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
  end
end
