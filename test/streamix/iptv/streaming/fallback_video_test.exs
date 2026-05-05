defmodule Streamix.Iptv.Streaming.FallbackVideoTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Streaming.FallbackVideo

  describe "category_from_reason/1" do
    test "maps 401/403 to :account_expired" do
      assert FallbackVideo.category_from_reason({:unexpected_status, 401}) == :account_expired
      assert FallbackVideo.category_from_reason({:unexpected_status, 403}) == :account_expired
    end

    test "maps 451 to :stream_blocked" do
      assert FallbackVideo.category_from_reason({:unexpected_status, 451}) == :stream_blocked
    end

    test "maps 429 / 509 to :rate_limited" do
      assert FallbackVideo.category_from_reason({:unexpected_status, 429}) == :rate_limited
      assert FallbackVideo.category_from_reason({:unexpected_status, 509}) == :rate_limited
    end

    test "maps other 4xx to :channel_unavailable" do
      assert FallbackVideo.category_from_reason({:unexpected_status, 404}) == :channel_unavailable
      assert FallbackVideo.category_from_reason({:unexpected_status, 410}) == :channel_unavailable
      assert FallbackVideo.category_from_reason(:upstream_not_found) == :channel_unavailable
    end

    test "maps 5xx and transport errors to :provider_unavailable" do
      assert FallbackVideo.category_from_reason({:unexpected_status, 502}) ==
               :provider_unavailable

      assert FallbackVideo.category_from_reason(:upstream_timeout) == :provider_unavailable

      assert FallbackVideo.category_from_reason(:stream_resolution_failed) ==
               :provider_unavailable

      assert FallbackVideo.category_from_reason(%Mint.TransportError{reason: :econnrefused}) ==
               :provider_unavailable
    end
  end

  describe "serve/2" do
    test "streams the prerendered MP4 with fallback header for known category" do
      conn =
        Plug.Test.conn(:get, "/stream/x")
        |> FallbackVideo.serve(:channel_unavailable)

      assert conn.state in [:file, :sent]
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["video/mp4"]

      assert Plug.Conn.get_resp_header(conn, "x-streamix-fallback") == [
               "channel_unavailable"
             ]

      assert byte_size(conn.resp_body || "") > 0 or conn.state == :file
    end

    test "all five categories have an asset on disk" do
      for category <- [
            :channel_unavailable,
            :provider_unavailable,
            :account_expired,
            :stream_blocked,
            :rate_limited
          ] do
        conn = Plug.Test.conn(:get, "/stream/x") |> FallbackVideo.serve(category)
        assert conn.state in [:file, :sent], "missing asset for #{category}"
      end
    end
  end
end
