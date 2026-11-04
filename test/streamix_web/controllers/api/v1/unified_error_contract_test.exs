defmodule StreamixWeb.Api.V1.UnifiedErrorContractTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures

  alias OpenApiSpex.Plug.PutApiSpec
  alias OpenApiSpex.TestAssertions
  alias Streamix.Accounts

  @protected [
    {"/api/v1/catalog/movies", "catalog.movies.list"},
    {"/api/v1/catalog/reels", "catalog.reels.list"},
    {"/api/v1/catalog/images/resize", "images.resize"},
    {"/api/v1/providers/status", "providers.status"},
    {"/api/v1/search/movies", "search.movies"},
    {"/api/v1/recommendations", "recommendations.index"},
    {"/api/v1/favorites", "favorites.index"},
    {"/api/v1/history", "history.index"},
    {"/api/v1/epg/programs", "epg.programs"},
    {"/api/v1/providers", "providers.index"}
  ]

  setup do
    original = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, ["error-contract-key"])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original) end)
    :ok
  end

  test "each JSON controller has a real routed failure with the shared envelope" do
    connections =
      Enum.map(@protected, fn {path, operation} ->
        build_conn()
        |> get(path)
        |> assert_error(401, "missing_api_key", operation)
      end)

    telemetry =
      build_conn()
      |> post("/api/v1/telemetry/playback", %{})
      |> assert_error(401, "missing_api_key", "telemetry.ingest")

    auth =
      build_conn()
      |> get("/api/v1/auth/me")
      |> assert_error(401, "unauthorized", "auth.me")

    tracks =
      build_conn()
      |> get("/api/gindex-tracks/movie/999999999")
      |> assert_error(404, "content_not_found", "tracks.show")

    # This anonymous endpoint has no 401/404/422 branch; invalid input is 400.
    subtitles =
      build_conn()
      |> get("/api/subtitles/invalid")
      |> assert_error(400, "invalid_imdb_id", "subtitles.show")

    exercised =
      Enum.map(
        [telemetry, auth, tracks, subtitles | connections],
        fn conn ->
          Phoenix.Router.route_info(StreamixWeb.Router, conn.method, conn.request_path, conn.host).plug
        end
      )
      |> MapSet.new()

    expected =
      StreamixWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.plug)
      |> Enum.filter(
        &(String.starts_with?(to_string(&1), "Elixir.StreamixWeb.Api.V1.") and
            &1 != StreamixWeb.Api.V1.OptionsController)
      )
      |> MapSet.new()

    assert exercised == expected
  end

  test "Bearer authentication rejects missing and invalid sessions across user resources" do
    for {method, path, operation} <- [
          {:get, "/api/v1/auth/me", "auth.me"},
          {:get, "/api/v1/favorites", "favorites.index"},
          {:get, "/api/v1/history", "history.index"},
          {:get, "/api/v1/providers", "providers.index"},
          {:get, "/api/v1/recommendations", "recommendations.index"},
          {:post, "/api/v1/telemetry/playback", "telemetry.ingest"}
        ],
        token <- [nil, "Bearer invalid-session"] do
      conn = integration_conn()
      conn = if token, do: put_req_header(conn, "authorization", token), else: conn

      conn
      |> dispatch(@endpoint, method, path, %{})
      |> assert_error(401, "unauthorized", operation)
    end
  end

  test "authenticated missing resources keep 404 and validation failures keep 422" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64()

    for {method, path, params, status, code, operation} <- [
          {:get, "/api/v1/catalog/movies/999999999", %{}, 404, "content_not_found",
           "catalog.movies.get"},
          {:delete, "/api/v1/providers/999999999", %{}, 404, "not_found", "providers.delete"},
          {:post, "/api/v1/favorites", %{type: "movie", content_id: 999_999_999}, 404,
           "content_not_found", "favorites.create"},
          {:post, "/api/v1/history", %{type: "movie", content_id: 999_999_999}, 404,
           "content_not_found", "history.upsert"},
          {:post, "/api/v1/favorites", %{type: "invalid", content_id: 1}, 422,
           "invalid_content_type", "favorites.create"},
          {:post, "/api/v1/history", %{type: "invalid", content_id: 1}, 422,
           "invalid_content_type", "history.upsert"},
          {:post, "/api/v1/providers", %{name: "", url: "invalid", username: "", password: ""},
           422, "validation_failed", "providers.create"},
          {:post, "/api/v1/auth/register", %{email: "invalid", password: "short"}, 422,
           "validation_failed", "auth.register"}
        ] do
      integration_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> dispatch(@endpoint, method, path, params)
      |> assert_error(status, code, operation)
    end
  end

  test "action fallback preserves resource-specific invalid-id messages" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64()

    for {path, operation, message} <- [
          {"/api/v1/providers/not-an-id", "providers.delete", "Invalid provider id"},
          {"/api/v1/history/not-an-id", "history.delete", "Invalid history id"}
        ] do
      conn =
        integration_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete(path)
        |> assert_error(400, "invalid_id", operation)

      assert json_response(conn, 400)["error"]["message"] == message
    end
  end

  test "CORS preflight intentionally returns an empty 204 without authentication" do
    conn =
      build_conn()
      |> put_req_header("origin", "https://example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/api/v1/favorites")

    assert response(conn, 204) == ""
  end

  defp integration_conn do
    put_req_header(build_conn(), "x-api-key", "error-contract-key")
  end

  defp assert_error(conn, status, expected_code, operation) do
    assert %{"error" => %{"code" => ^expected_code, "message" => message}} =
             json_response(conn, status)

    assert is_binary(message) and byte_size(message) > 0
    assert Map.keys(json_response(conn, status)) == ["error"]

    conn
    |> PutApiSpec.call(StreamixWeb.Api.V1.OpenApi)
    |> TestAssertions.assert_operation_response(operation)
  end
end
