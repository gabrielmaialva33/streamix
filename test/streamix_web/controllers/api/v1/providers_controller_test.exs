defmodule StreamixWeb.Api.V1.ProvidersControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures

  alias Streamix.Accounts

  test "create returns formatted validation errors for invalid payload", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    api_key = List.first(original_api_keys) || "test-api-key"

    if original_api_keys == [] do
      Application.put_env(:streamix, :api_keys, [api_key])

      on_exit(fn ->
        Application.put_env(:streamix, :api_keys, original_api_keys)
      end)
    end

    conn =
      conn
      |> put_req_header("x-api-key", api_key)
      |> put_req_header("authorization", "Bearer #{Base.url_encode64(token)}")
      |> post(~p"/api/v1/providers", %{
        "name" => "",
        "url" => "not-a-url",
        "username" => "",
        "password" => ""
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => message
             }
           } = json_response(conn, 422)

    assert message =~ "name: can't be blank"
    assert message =~ "url: must be a valid HTTP/HTTPS URL"
    assert message =~ "username: can't be blank"
    assert message =~ "password: can't be blank"
  end
end
