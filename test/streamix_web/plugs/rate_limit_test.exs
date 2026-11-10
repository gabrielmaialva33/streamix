defmodule StreamixWeb.Plugs.RateLimitTest do
  # async: false because we override the global :disable_rate_limit config
  # (set to true for E2E tests) for this specific test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias StreamixWeb.Plugs.RateLimit

  setup do
    previous = Application.get_env(:streamix, :disable_rate_limit)
    Application.put_env(:streamix, :disable_rate_limit, false)
    on_exit(fn -> Application.put_env(:streamix, :disable_rate_limit, previous) end)
    :ok
  end

  test "rate limits by Cloudflare client ip instead of shared remote_ip" do
    conn_a =
      conn(:post, "/login")
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 65_535, 44_050, 1})
      |> put_req_header("cf-connecting-ip", "198.51.100.10")

    conn_b =
      conn(:post, "/login")
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 65_535, 44_050, 1})
      |> put_req_header("cf-connecting-ip", "198.51.100.11")

    opts = RateLimit.init(name: :cf_ip_test, limit: 1, period: 60_000)

    allowed_conn = RateLimit.call(conn_a, opts)
    assert allowed_conn.halted == false
    assert get_resp_header(allowed_conn, "x-ratelimit-remaining") == ["0"]

    capture_log(fn ->
      denied_conn = RateLimit.call(conn_a, opts)
      assert denied_conn.halted
      assert denied_conn.status == 429
    end)

    other_ip_conn = RateLimit.call(conn_b, opts)
    assert other_ip_conn.halted == false
    assert get_resp_header(other_ip_conn, "x-ratelimit-remaining") == ["0"]
  end

  test "each named bucket keeps its own count for the same client" do
    viewer =
      conn(:get, "/api/stream/proxy")
      |> put_req_header("cf-connecting-ip", "198.51.100.20")

    segments = RateLimit.init(name: :bucket_test_segments, limit: 100, period: 60_000)
    login = RateLimit.init(name: :bucket_test_login, limit: 1, period: 60_000)

    # A busy stream spends its own bucket...
    for _ <- 1..50, do: refute(RateLimit.call(viewer, segments).halted)

    # ...and leaves the login allowance of the same viewer untouched.
    allowed = RateLimit.call(viewer, login)
    refute allowed.halted
    assert get_resp_header(allowed, "x-ratelimit-remaining") == ["0"]
  end

  test "a bucket must be named" do
    assert_raise KeyError, fn -> RateLimit.init(limit: 1, period: 60_000) end
  end
end
