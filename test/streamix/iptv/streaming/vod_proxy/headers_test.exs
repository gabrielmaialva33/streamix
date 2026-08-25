defmodule Streamix.Iptv.Streaming.VodProxy.HeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Streamix.Iptv.Streaming.VodProxy.Headers

  describe "request/2" do
    test "forwards player cache and range headers without leaking unrelated headers" do
      conn =
        conn(:get, "/proxy")
        |> put_req_header("range", "bytes=100-200")
        |> put_req_header("if-range", "stream-v1")
        |> put_req_header("authorization", "secret")

      headers = Headers.request(conn, 0)

      assert {"range", "bytes=100-200"} in headers
      assert {"if-range", "stream-v1"} in headers
      assert {"connection", "close"} in headers
      assert {"accept", "*/*"} in headers
      assert List.keymember?(headers, "user-agent", 0)
      refute List.keymember?(headers, "authorization", 0)
    end

    test "replaces the player range with the exact resume offset" do
      conn =
        conn(:get, "/proxy")
        |> put_req_header("range", "bytes=0-99")
        |> put_req_header("if-range", "stream-v1")

      headers = Headers.request(conn, 4_096)

      assert Enum.filter(headers, &match?({"range", _value}, &1)) == [
               {"range", "bytes=4096-"}
             ]

      assert {"if-range", "stream-v1"} in headers
    end
  end

  test "HEAD copies only playback metadata and adds the proxy response policy" do
    response =
      Headers.send_head(conn(:head, "/proxy"), 206, [
        {"content-type", "video/mp4"},
        {"content-length", "1234"},
        {"etag", "stream-v1"},
        {"set-cookie", "upstream-secret"}
      ])

    assert response.status == 206
    assert response.state == :sent
    assert get_resp_header(response, "content-type") == ["video/mp4"]
    assert get_resp_header(response, "content-length") == ["1234"]
    assert get_resp_header(response, "etag") == ["stream-v1"]
    assert get_resp_header(response, "accept-ranges") == ["bytes"]
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert get_resp_header(response, "set-cookie") == []
  end

  test "a resumed chunked response does not advertise the remaining range as a new body" do
    response =
      Headers.send_chunked(
        conn(:get, "/proxy"),
        206,
        [
          {"content-type", "video/mp4"},
          {"content-length", "512"},
          {"content-range", "bytes 512-1023/1024"}
        ],
        true
      )

    assert response.state == :chunked
    assert get_resp_header(response, "content-type") == ["video/mp4"]
    assert get_resp_header(response, "content-length") == []
    assert get_resp_header(response, "content-range") == []
    assert get_resp_header(response, "accept-ranges") == ["bytes"]
  end
end
