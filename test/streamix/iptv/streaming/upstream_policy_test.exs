defmodule Streamix.Iptv.Streaming.UpstreamPolicyTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Streaming.UpstreamPolicy

  setup do
    previous = Application.get_env(:streamix, :iptv_upstream_user_agent)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:streamix, :iptv_upstream_user_agent)
        value -> Application.put_env(:streamix, :iptv_upstream_user_agent, value)
      end
    end)

    :ok
  end

  test "uses the configured provider identity" do
    Application.put_env(:streamix, :iptv_upstream_user_agent, "StreamixProviderClient/1")

    assert UpstreamPolicy.user_agent() == "StreamixProviderClient/1"
  end

  test "falls back when the configured identity is blank" do
    Application.put_env(:streamix, :iptv_upstream_user_agent, "")

    assert UpstreamPolicy.user_agent() == "IPTVSmartersPlayer"
  end

  test "domain identity is opt-in, exact-host scoped and strips stale headers" do
    provider =
      struct(Provider, url: "https://PANEL.example", urls: ["https://alt.example"])

    flagged = Map.put(provider, :send_x_domain, true)
    policy = UpstreamPolicy.domain_policy(flagged)
    domain = URI.parse(StreamixWeb.Endpoint.url()).host

    assert UpstreamPolicy.headers("https://panel.example/movie/u/p/1", [], policy) == [
             {"x-domain", domain}
           ]

    assert UpstreamPolicy.headers("http://alt.example/player_api.php", [], policy) == [
             {"x-domain", domain}
           ]

    for url <- ["https://cdn.example/1", "https://panel.example.evil/1"] do
      assert UpstreamPolicy.headers(url, [{"X-Domain", "stale"}], policy) == []
    end

    assert UpstreamPolicy.headers(
             "https://panel.example/1",
             [],
             UpstreamPolicy.domain_policy(provider)
           ) == []
  end

  test "only the operator changeset accepts send_x_domain" do
    provider = struct(Provider)

    assert Ecto.Changeset.get_change(
             Provider.changeset(provider, %{send_x_domain: true}),
             :send_x_domain
           ) == true

    refute Ecto.Changeset.get_change(
             Provider.user_changeset(provider, %{send_x_domain: true}),
             :send_x_domain
           )
  end
end
