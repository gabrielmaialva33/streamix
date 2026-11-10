defmodule StreamixWeb.ErrorJSONTest do
  use StreamixWeb.ConnCase, async: true

  test "API errors use the stable envelope without exposing exception details" do
    conn = build_conn(:get, "/api/v1/missing")

    assert StreamixWeb.ErrorJSON.render("404.json", %{conn: conn}) ==
             %{error: %{code: "not_found", message: "Not Found"}}

    assert StreamixWeb.ErrorJSON.render("500.json", %{conn: conn, reason: "private"}) ==
             %{error: %{code: "internal_server_error", message: "Internal Server Error"}}
  end

  test "unknown API routes render the same envelope through the endpoint" do
    body =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/v1/unknown-error-contract-route")
      |> json_response(404)

    assert body == %{"error" => %{"code" => "not_found", "message" => "Not Found"}}
  end

  test "similar browser paths keep their existing envelope" do
    conn = build_conn(:get, "/apiary")

    assert StreamixWeb.ErrorJSON.render("404.json", %{conn: conn}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 404" do
    assert StreamixWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert StreamixWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
