defmodule Streamix.Iptv.Streaming.StreamMultiplexer.UpstreamTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Streaming.StreamMultiplexer.Upstream

  describe "normalize_urls/1" do
    test "normalizes one URL and removes invalid or repeated candidates" do
      assert Upstream.normalize_urls("https://provider.test/live") == [
               "https://provider.test/live"
             ]

      assert Upstream.normalize_urls([
               "https://provider.test/live",
               nil,
               "",
               "https://provider.test/fallback",
               "https://provider.test/live"
             ]) == [
               "https://provider.test/live",
               "https://provider.test/fallback"
             ]

      assert Upstream.normalize_urls(:invalid) == []
    end
  end

  test "keeps only response headers that are safe to forward" do
    headers = [
      {"Content-Type", "video/mp2t"},
      {"ETag", "stream-v1"},
      {"Set-Cookie", "upstream-secret"},
      {"Connection", "keep-alive"}
    ]

    assert Upstream.filter_response_headers(headers) == [
             {"Content-Type", "video/mp2t"},
             {"ETag", "stream-v1"}
           ]
  end

  test "resolves relative redirects against the active upstream URL" do
    assert Upstream.resolve_url(
             "https://provider.test/live/channel/index.m3u8?token=old",
             "../fallback/playlist.m3u8?token=new"
           ) == "https://provider.test/live/fallback/playlist.m3u8?token=new"
  end

  test "sanitizes transport errors before they reach subscribers" do
    assert Upstream.safe_reason({:unexpected_status, 503}) == {:unexpected_status, 503}
    assert Upstream.safe_reason(:timeout) == :timeout
    assert Upstream.safe_reason(%URI{}) == URI
    assert Upstream.safe_reason({:error, "sensitive upstream detail"}) == :upstream_error
  end
end
