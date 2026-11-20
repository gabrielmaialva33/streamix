defmodule Streamix.PlaybackTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Streaming.ProviderEndpoints
  alias Streamix.Playback

  defp provider do
    %Provider{
      id: 3_000_000 + System.unique_integer([:positive]),
      url: "https://primary.test",
      urls: ["https://alt.test"],
      username: "user",
      password: "pass",
      provider_type: :xtream
    }
  end

  test "provider_stream_url_chain/2 follows the ranked endpoint order" do
    provider = provider()

    assert :ok = ProviderEndpoints.report(provider, "https://alt.test", :ok)

    assert Playback.provider_stream_url_chain(provider, "https://alt.test/live/user/pass/1.ts") ==
             ["https://alt.test/live/user/pass/1.ts", "https://primary.test/live/user/pass/1.ts"]
  end

  test "provider_base_url/1 returns the preferred base" do
    provider = provider()

    assert Playback.provider_base_url(provider) == "https://primary.test"

    assert :ok = ProviderEndpoints.report(provider, "https://primary.test", :down)
    assert Playback.provider_base_url(provider) == "https://alt.test"
  end
end
