defmodule StreamixWeb.Api.V1.HistoryControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Accounts
  alias Streamix.Iptv

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    :ok
  end

  describe "POST /api/v1/history" do
    test "index clamps invalid pagination instead of crashing", %{conn: conn} do
      user = user_fixture()

      response =
        conn
        |> authenticated(user)
        |> get(~p"/api/v1/history?limit=-1&offset=-10")
        |> json_response(200)

      assert response == %{"items" => []}
    end

    test "allows recording own private playable content", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/history", %{
          "type" => "movie",
          "content_id" => movie.id,
          "progress_seconds" => 120
        })
        |> json_response(201)

      assert response["content_type"] == "movie"
      assert response["content_id"] == movie.id
      movie_id = movie.id
      assert [%{content_id: ^movie_id}] = Iptv.list_watch_history(user.id)
    end

    test "blocks recording another user's private playable content", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      other_provider = provider_fixture(other_user)
      movie = movie_fixture(other_provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/history", %{
          "type" => "movie",
          "content_id" => movie.id,
          "progress_seconds" => 120
        })
        |> json_response(404)

      assert response["error"]["code"] == "content_not_found"
      assert Iptv.list_watch_history(user.id) == []
    end
  end

  defp authenticated(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer #{Base.url_encode64(token)}")
  end
end
