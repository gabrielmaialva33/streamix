defmodule StreamixWeb.InternalDiagControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    previous = Application.get_env(:streamix, :disable_rate_limit)
    Application.put_env(:streamix, :disable_rate_limit, false)

    on_exit(fn ->
      Application.put_env(:streamix, :disable_rate_limit, previous)
    end)

    :ok
  end

  test "bounds public diagnostic data and uses its dedicated rate limit", %{conn: conn} do
    oversized_ua = "mobile\n" <> String.duplicate("x", 500) <> "DO_NOT_LOG"

    log =
      capture_log(fn ->
        conn =
          post(conn, ~p"/api/internal/home-stuck", %{
            "ua" => oversized_ua,
            "transport" => %{"nested" => "payload"},
            "connected" => true,
            "ignored" => "DO_NOT_LOG"
          })

        assert response(conn, 204) == ""
        assert get_resp_header(conn, "x-ratelimit-limit") == ["6"]
      end)

    assert log =~ "[home-stuck]"
    assert log =~ "mobile "
    assert log =~ ~s("transport" => "[unsupported]")
    refute log =~ "DO_NOT_LOG"
    refute log =~ ~s("ignored")
  end
end
