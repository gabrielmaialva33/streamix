defmodule StreamixWeb.Api.V1.ProvidersControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.{Accounts, Repo}

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)
    :ok
  end

  test "index serializes the live-channel counter without exposing credentials", %{conn: conn} do
    user = user_fixture()
    provider = provider_fixture(user, %{live_channels_count: 7})
    token = Accounts.generate_user_session_token(user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{Base.url_encode64(token)}")
      |> get(~p"/api/v1/providers")
      |> json_response(200)

    assert [%{"id" => id, "channels_count" => 7} = payload] = response["providers"]
    assert id == provider.id
    refute Map.has_key?(payload, "username")
    refute Map.has_key?(payload, "password")
  end

  test "index strips credentials and query data from legacy provider URLs", %{conn: conn} do
    user = user_fixture()

    provider =
      user
      |> provider_fixture()
      |> Ecto.Changeset.change(%{
        url: "https://legacy-user:legacy-secret@provider.example.com/base?token=secret#fragment"
      })
      |> Repo.update!()

    token = Accounts.generate_user_session_token(user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{Base.url_encode64(token)}")
      |> get(~p"/api/v1/providers")
      |> json_response(200)

    assert [%{"id" => id, "url" => "https://provider.example.com/base"}] = response["providers"]
    assert id == provider.id
  end

  test "create returns formatted validation errors for invalid payload", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
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

  test "create rejects an HTTP scheme without a host", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{Base.url_encode64(token)}")
      |> post(~p"/api/v1/providers", %{
        "name" => "Broken",
        "url" => "http:",
        "username" => "user",
        "password" => "secret"
      })
      |> json_response(422)

    assert response["error"]["code"] == "validation_failed"
    assert response["error"]["message"] =~ "url: must be a valid HTTP/HTTPS URL"
  end
end
