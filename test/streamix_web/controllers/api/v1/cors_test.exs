defmodule StreamixWeb.Api.V1.CorsTest do
  use StreamixWeb.ConnCase, async: false

  setup do
    original_cors = Application.get_env(:streamix, :cors)
    original_api_keys = Application.get_env(:streamix, :api_keys)

    Application.put_env(:streamix, :cors, origins: ["https://client.example"])
    Application.put_env(:streamix, :api_keys, ["protected-api-key"])

    on_exit(fn ->
      restore_env(:cors, original_cors)
      restore_env(:api_keys, original_api_keys)
    end)

    :ok
  end

  test "catch-all preflight covers authenticated v1 resources without credentials", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://client.example")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization,x-api-key")
      |> options("/api/v1/recommendations/refresh")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://client.example"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "catch-all preflight also covers auth routes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://client.example")
      |> options("/api/v1/auth/login")

    assert response(conn, 204) == ""
  end

  test "disallowed origins get no CORS grant but still vary caches by origin", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://attacker.example")
      |> options("/api/v1/auth/login")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  defp restore_env(key, nil), do: Application.delete_env(:streamix, key)
  defp restore_env(key, value), do: Application.put_env(:streamix, key, value)
end
