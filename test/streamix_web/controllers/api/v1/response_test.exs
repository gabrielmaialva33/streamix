defmodule StreamixWeb.Api.V1.ResponseTest do
  use StreamixWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias StreamixWeb.Api.V1.Response

  test "renders the stable API error envelope", %{conn: conn} do
    conn =
      Response.error(
        conn,
        :bad_request,
        "invalid_id",
        "Invalid content id",
        field: "id"
      )

    assert json_response(conn, 400) == %{
             "error" => %{
               "code" => "invalid_id",
               "message" => "Invalid content id",
               "field" => "id"
             }
           }
  end

  test "internal errors do not expose or log the raw reason", %{conn: conn} do
    secret = "upstream-token-must-not-leak"

    log =
      capture_log(fn ->
        conn =
          Response.internal_error(
            conn,
            :service_unavailable,
            "search_failed",
            "Search is temporarily unavailable",
            {:upstream_error, secret}
          )

        send(self(), {:response_conn, conn})
      end)

    assert_receive {:response_conn, conn}
    assert get_in(json_response(conn, 503), ["error", "code"]) == "search_failed"
    refute conn.resp_body =~ secret
    refute log =~ secret
  end
end
