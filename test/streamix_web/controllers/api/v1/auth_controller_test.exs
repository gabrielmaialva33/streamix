defmodule StreamixWeb.Api.V1.AuthControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures

  test "me and logout share the Bearer parser and accept case-insensitive unpadded tokens", %{
    conn: conn
  } do
    user = user_fixture()
    encoded = user |> api_token_fixture() |> String.trim_trailing("=")

    me =
      conn
      |> put_req_header("authorization", "BEARER   #{encoded}")
      |> get(~p"/api/v1/auth/me")
      |> json_response(200)

    assert me["user"]["id"] == user.id

    assert conn
           |> put_req_header("authorization", "bearer #{encoded}")
           |> post(~p"/api/v1/auth/logout")
           |> response(204)

    unauthorized =
      conn
      |> put_req_header("authorization", "Bearer #{encoded}")
      |> get(~p"/api/v1/auth/me")
      |> json_response(401)

    assert unauthorized["error"]["code"] == "unauthorized"
  end

  test "login returns a token that carries the library secret, and it opens the library", %{
    conn: conn
  } do
    user = user_fixture()

    %{"token" => token} =
      conn
      |> post(~p"/api/v1/auth/login", %{
        "email" => user.email,
        "password" => valid_user_password()
      })
      |> json_response(200)

    assert {:ok, credentials} = Base.url_decode64(token)
    assert byte_size(credentials) == 64

    assert %{"items" => []} =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(~p"/api/v1/history")
             |> json_response(200)
  end

  test "logout stays idempotent without a token", %{conn: conn} do
    assert conn |> post(~p"/api/v1/auth/logout") |> response(204)
  end

  test "failed login audit does not log the submitted email", %{conn: conn} do
    email = "private-login@example.com"

    log =
      capture_log(fn ->
        response =
          conn
          |> post(~p"/api/v1/auth/login", %{"email" => email, "password" => "wrong"})
          |> json_response(401)

        assert response["error"]["code"] == "invalid_credentials"
      end)

    refute log =~ email
    assert log =~ "login failed account="
  end

  test "rejects non-string auth credentials without crashing", %{conn: conn} do
    for path <- [~p"/api/v1/auth/login", ~p"/api/v1/auth/register"] do
      response =
        conn
        |> post(path, %{"email" => 123, "password" => ["invalid"]})
        |> json_response(400)

      assert response["error"]["code"] == "missing_params"
    end
  end
end
