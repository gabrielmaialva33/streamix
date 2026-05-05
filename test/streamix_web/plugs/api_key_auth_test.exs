defmodule StreamixWeb.Plugs.ApiKeyAuthTest do
  # The plug reads from application env, so parallel tests would race
  # each other when swapping the configured key list.
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias StreamixWeb.Plugs.ApiKeyAuth

  @key "test-api-key-xyz"

  setup do
    original = Application.get_env(:streamix, :api_keys)
    Application.put_env(:streamix, :api_keys, [@key])

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, :api_keys, original),
        else: Application.delete_env(:streamix, :api_keys)
    end)

    :ok
  end

  describe "call/2 — header transport (canonical)" do
    test "accepts a request with a valid X-API-Key header" do
      conn =
        build_conn(:get, "/any")
        |> Plug.Conn.put_req_header("x-api-key", @key)
        |> ApiKeyAuth.call([])

      refute conn.halted
    end

    test "rejects a bogus header" do
      capture_log(fn ->
        conn =
          build_conn(:get, "/any")
          |> Plug.Conn.put_req_header("x-api-key", "wrong")
          |> ApiKeyAuth.call([])

        assert conn.halted
        assert conn.status == 401
      end)
    end
  end

  describe "call/2 — query-string fallback (for <img src> use cases)" do
    # Regression: browsers/Lightning can't set custom headers on image
    # requests, so the TV app needs `?api_key=` to authenticate resize
    # URLs embedded directly in DOM <img> tags.
    test "accepts a valid ?api_key= parameter when no header is present" do
      conn =
        build_conn(:get, "/any?api_key=#{URI.encode_www_form(@key)}")
        |> ApiKeyAuth.call([])

      refute conn.halted
    end

    test "rejects a bogus ?api_key= parameter" do
      capture_log(fn ->
        conn =
          build_conn(:get, "/any?api_key=wrong")
          |> ApiKeyAuth.call([])

        assert conn.halted
        assert conn.status == 401
      end)
    end

    test "treats an empty ?api_key= as missing, not invalid" do
      conn =
        build_conn(:get, "/any?api_key=")
        |> ApiKeyAuth.call([])

      assert conn.halted
      # Missing surfaces as a 401 with "Missing API key" copy.
      body = Phoenix.ConnTest.json_response(conn, 401)
      assert body["message"] =~ "Missing"
    end
  end

  describe "call/2 — precedence" do
    test "header beats query string when both are present" do
      # A valid header + an invalid query param should be accepted.
      # (Defence in depth: if a middlebox ever rewrites query params,
      # the header still authenticates the caller.)
      conn =
        build_conn(:get, "/any?api_key=wrong")
        |> Plug.Conn.put_req_header("x-api-key", @key)
        |> ApiKeyAuth.call([])

      refute conn.halted
    end
  end
end
