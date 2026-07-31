defmodule Streamix.Iptv.Streaming.UpstreamPolicyTest do
  use ExUnit.Case, async: false

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
end
