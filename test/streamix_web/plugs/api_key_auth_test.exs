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

  describe "call/2 — query string rejected" do
    # Hardened in 2026-06: API keys are header-only. The previous
    # `?api_key=` fallback for image-embedded resize URLs leaked keys
    # into access logs, browser history and referer headers. Callers
    # without header support must use a signed StreamToken.
    test "ignores a valid ?api_key= parameter and 401s as if missing" do
      conn =
        build_conn(:get, "/any?api_key=#{URI.encode_www_form(@key)}")
        |> ApiKeyAuth.call([])

      assert conn.halted
      body = Phoenix.ConnTest.json_response(conn, 401)
      assert body["error"]["code"] == "missing_api_key"
      assert body["error"]["message"] =~ "Missing"
    end

    test "header still beats querystring noise" do
      conn =
        build_conn(:get, "/any?api_key=wrong")
        |> Plug.Conn.put_req_header("x-api-key", @key)
        |> ApiKeyAuth.call([])

      refute conn.halted
    end
  end
end
