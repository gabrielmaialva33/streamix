defmodule StreamixWeb.Api.V1.AuthControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures

  alias Streamix.Accounts

  test "me and logout share the Bearer parser and accept case-insensitive unpadded tokens", %{
    conn: conn
  } do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    encoded = Base.url_encode64(token, padding: false)

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

  test "registering an email already in use answers 422, not 500", %{conn: conn} do
    user_fixture(%{email: "taken@example.com"})

    response =
      conn
      |> post(~p"/api/v1/auth/register", %{
        "email" => "taken@example.com",
        "password" => "a valid password 123"
      })
      |> json_response(422)

    assert response["error"]["code"] == "validation_failed"
    assert response["error"]["message"] =~ "email"
  end
end
