defmodule StreamixWeb.Content.LiveChannelsSyncProgressTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "provider sync broadcasts" do
    setup %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user, %{name: "Sync Progress Catalog"})
      channel = channel_fixture(provider, %{name: "Sync Progress Channel"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/providers/#{provider.id}")

      %{view: view, provider: provider, channel: channel}
    end

    test "ignores :sync_progress ticks for every content type without crashing", %{
      view: view,
      provider: provider,
      channel: channel
    } do
      # Mirrors Streamix.Iptv.Sync.Telemetry.broadcast_progress/4, which fans out
      # live, movies, series, and categories progress on the provider topic.
      for type <- [:categories, :live, :movies, :series], percent <- [0, 67, 100] do
        Phoenix.PubSub.broadcast(
          Streamix.PubSub,
          "provider:#{provider.id}",
          {:sync_progress,
           %{
             event: :sync_progress,
             provider_id: provider.id,
             phase: :content,
             percent: percent,
             type: type
           }}
        )
      end

      # A synchronous render proves the LiveView process handled every message
      # above and is still alive, with its catalog intact.
      assert render(view) =~ "Sync Progress Channel"
      assert has_element?(view, "#channel-img-#{channel.id}")
    end
  end
end
