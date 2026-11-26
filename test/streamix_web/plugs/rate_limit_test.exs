defmodule StreamixWeb.Plugs.RateLimitTest do
  # async: false because we override the global :disable_rate_limit config
  # (set to true for E2E tests) for this specific test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias StreamixWeb.Plugs.RateLimit

  setup do
    old_proxies = Application.get_env(:streamix, :trusted_proxy_cidrs, [])
    Application.put_env(:streamix, :trusted_proxy_cidrs, [{{127, 0, 0, 1}, 32}])
    on_exit(fn -> Application.put_env(:streamix, :trusted_proxy_cidrs, old_proxies) end)
    previous = Application.get_env(:streamix, :disable_rate_limit)
    Application.put_env(:streamix, :disable_rate_limit, false)
    on_exit(fn -> Application.put_env(:streamix, :disable_rate_limit, previous) end)
    :ok
  end

  test "rate limits by trusted proxy client ip instead of shared remote_ip" do
    conn_a =
      conn(:post, "/login")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "198.51.100.10")

    conn_b =
      conn(:post, "/login")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "198.51.100.11")

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
      |> put_req_header("x-forwarded-for", "198.51.100.20")

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

  test "rotating spoofed forwarding headers cannot reset an untrusted peer's bucket" do
    opts = RateLimit.init(name: :spoofed_forwarded_test, limit: 1, period: 60_000)

    first =
      conn(:post, "/login")
      |> Map.put(:remote_ip, {203, 0, 113, 101})
      |> put_req_header("x-forwarded-for", "198.51.100.100")

    refute RateLimit.call(first, opts).halted

    capture_log(fn ->
      assert first
             |> put_req_header("x-forwarded-for", "198.51.100.101")
             |> RateLimit.call(opts)
             |> Map.fetch!(:halted)
    end)
  end
end
