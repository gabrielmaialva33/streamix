defmodule Streamix.Iptv.Streaming.ResponsePolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Streamix.Iptv.Streaming.ResponsePolicy

  test "VOD responses expose range metadata without shared caching" do
    conn =
      conn(:get, "/stream")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ResponsePolicy.put_vod()

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["cross-origin"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    [exposed] = get_resp_header(conn, "access-control-expose-headers")
    assert exposed =~ "Content-Range"
    assert exposed =~ "ETag"

    assert get_resp_header(conn, "vary") == ["Accept-Encoding, Origin, Range"]
  end

  test "live responses disable intermediary and reverse-proxy buffering" do
    conn = conn(:get, "/live") |> ResponsePolicy.put_live()

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    assert get_resp_header(conn, "vary") == ["Origin, Range"]
  end

  test "Vary values are deduplicated case-insensitively" do
    conn =
      conn(:get, "/stream")
      |> put_resp_header("vary", "origin, Accept-Encoding")
      |> ResponsePolicy.put_vod()

    assert get_resp_header(conn, "vary") == ["origin, Accept-Encoding, Range"]
  end
end
