defmodule StreamixWeb.Api.V1.CatalogHomeTest do
  use StreamixWeb.ConnCase, async: false

  @api_key "home-test-key"

  setup do
    original_keys = Application.get_env(:streamix, :api_keys)
    Application.put_env(:streamix, :api_keys, [@api_key])

    on_exit(fn ->
      if original_keys,
        do: Application.put_env(:streamix, :api_keys, original_keys),
        else: Application.delete_env(:streamix, :api_keys)
    end)

    :ok
  end

  describe "GET /api/v1/catalog/home" do
    test "returns the full home payload with every expected section key" do
      # The TV app depends on these five keys being present on every
      # response — even when the underlying query returns an empty list.
      # That way the client renderer can always iterate `payload[key]`
      # without a nil-check and the absence of content is just an empty
      # array, not a 404 section.
      conn =
        build_conn()
        |> put_req_header("x-api-key", @api_key)
        |> get("/api/v1/catalog/home?limit=5")

      body = json_response(conn, 200)

      for key <- [
            "featured",
            "trending_movies",
            "recent_movies",
            "top_rated_movies",
            "trending_series"
          ] do
        assert Map.has_key?(body, key), "missing section key: #{key}"
      end

      # Four of the five are lists; `featured` is a map-or-nil.
      for key <- ["trending_movies", "recent_movies", "top_rated_movies", "trending_series"] do
        assert is_list(body[key]), "#{key} must be a list, got #{inspect(body[key])}"
      end
    end

    test "rejects unauthenticated requests" do
      conn = get(build_conn(), "/api/v1/catalog/home")
      assert conn.status == 401
    end

    test "rejects api_key passed via query string (header-only after 2026-06 hardening)" do
      conn = get(build_conn(), "/api/v1/catalog/home?api_key=#{@api_key}&limit=2")
      assert conn.status == 401
    end
  end
end
