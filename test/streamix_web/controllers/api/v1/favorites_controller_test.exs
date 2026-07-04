defmodule StreamixWeb.Api.V1.FavoritesControllerTest do
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

  describe "POST /api/v1/favorites" do
    test "index clamps invalid limits instead of crashing", %{conn: conn} do
      user = user_fixture()

      response =
        conn
        |> authenticated(user)
        |> get(~p"/api/v1/favorites?limit=-1")
        |> json_response(200)

      assert response == %{"favorites" => []}
    end

    test "allows favoriting own private content", %{conn: conn} do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/favorites", %{"type" => "movie", "content_id" => movie.id})
        |> json_response(201)

      assert get_in(response, ["data", "content_type"]) == "movie"
      assert Iptv.favorite?(user.id, "movie", movie.id)
    end

    test "blocks favoriting another user's private content", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      other_provider = provider_fixture(other_user)
      movie = movie_fixture(other_provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/favorites", %{"type" => "movie", "content_id" => movie.id})
        |> json_response(404)

      assert response["error"]["code"] == "content_not_found"
      refute Iptv.favorite?(user.id, "movie", movie.id)
    end
  end

  describe "POST /api/v1/favorites/toggle" do
    test "blocks adding another user's private content", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      other_provider = provider_fixture(other_user)
      movie = movie_fixture(other_provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/favorites/toggle", %{"type" => "movie", "content_id" => movie.id})
        |> json_response(404)

      assert response["error"]["code"] == "content_not_found"
      refute Iptv.favorite?(user.id, "movie", movie.id)
    end
  end

  describe "POST /api/v1/favorites/sync" do
    test "skips malformed operations instead of crashing the batch", %{conn: conn} do
      user = user_fixture()

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/favorites/sync", %{
          "operations" => [
            %{"type" => "movie", "content_id" => "abc", "action" => "add"}
          ]
        })
        |> json_response(200)

      assert response == %{"added" => 0, "removed" => 0, "skipped" => 1}
    end

    test "skips add operations for another user's private content", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      other_provider = provider_fixture(other_user)
      movie = movie_fixture(other_provider)

      response =
        conn
        |> authenticated(user)
        |> post(~p"/api/v1/favorites/sync", %{
          "operations" => [
            %{"type" => "movie", "content_id" => movie.id, "action" => "add"}
          ]
        })
        |> json_response(200)

      assert response == %{"added" => 0, "removed" => 0, "skipped" => 1}
      refute Iptv.favorite?(user.id, "movie", movie.id)
    end
  end

  defp authenticated(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer #{Base.url_encode64(token)}")
  end
end
