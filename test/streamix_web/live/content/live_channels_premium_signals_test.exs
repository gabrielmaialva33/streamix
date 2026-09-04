defmodule StreamixWeb.Content.LiveChannelsPremiumSignalsTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv
  alias Streamix.Repo

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

      assert {:error, {:redirect, %{to: watch_path}}} =
               render_hook(view, "play_channel", %{"id" => channel.id})

      assert watch_path == "/watch/live_channel/#{channel.id}"
    end

    test "play_channel never renders upstream provider credentials into the DOM", %{conn: conn} do
      user = user_fixture()

      provider =
        provider_fixture(user, %{
          name: "Credential Leak Guard",
          username: "leaky-user",
          password: "leaky-pass"
        })

      channel = channel_fixture(provider, %{name: "Credential Guard Channel"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse")

      refute html =~ "leaky-user"
      refute html =~ "leaky-pass"

      # The only playback entrypoint is the signed-token route; no inline
      # player may exist, because building one requires the upstream URL and
      # that URL embeds the provider username and password.
      assert {:error, {:redirect, _}} = render_hook(view, "play_channel", %{"id" => channel.id})
    end

    test "categories are only shown and applied after a provider is selected", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Private Live Catalog"})

      category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Esportes",
          type: "live",
          external_id: "live-sports"
        })

      matching = channel_fixture(provider, %{name: "Sports Private Channel"})
      other = channel_fixture(provider, %{name: "News Private Channel"})

      Repo.insert_all("item_categories", [
        %{catalog_item_id: matching.catalog_item_id, category_id: category.id}
      ])

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/browse?search=private")

      assert has_element?(view, "#provider-dropdown")
      assert html =~ ~s(href="/browse/movies?search=private")
      assert html =~ ~s(href="/browse/series?search=private")
      refute has_element?(view, "button", "Esportes")
      assert has_element?(view, "#channel-img-#{matching.id}")
      assert has_element?(view, "#channel-img-#{other.id}")

      {:ok, view, _html} = live(conn, ~p"/browse?category=#{category.id}")

      refute has_element?(view, "button", "Esportes")
      assert has_element?(view, "#channel-img-#{matching.id}")
      assert has_element?(view, "#channel-img-#{other.id}")

      {:ok, view, _html} = live(conn, ~p"/browse?provider=#{provider.id}")

      assert has_element?(view, "button", "Esportes")

      {:ok, view, _html} = live(conn, ~p"/browse?provider=#{provider.id}&category=#{category.id}")

      assert has_element?(view, ".category-pill--sidebar-active", "Esportes")
      assert has_element?(view, "#channel-img-#{matching.id}")
      refute has_element?(view, "#channel-img-#{other.id}")
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

      # An unplayable channel must not redirect into the player either.
      refute match?({:error, {:redirect, _}}, play_html)
      refute favorite_html =~ ~s(id="channel-img-#{private_channel.id}")
      refute refresh_html =~ "Other Private Channel"
      refute Iptv.favorite?(user.id, "live_channel", private_channel.id)
    end
  end
end
