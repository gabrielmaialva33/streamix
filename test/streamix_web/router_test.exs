defmodule StreamixWeb.RouterTest do
  use StreamixWeb.ConnCase, async: true

  describe "legacy GIndex movies route" do
    setup :register_and_log_in_user

    test "redirects without mounting a LiveView", %{conn: conn} do
      conn = get(conn, "/gindex/movies")
      assert redirected_to(conn, 302) == "/browse/movies?source=gindex"
      route = Phoenix.Router.route_info(StreamixWeb.Router, "GET", "/gindex/movies", "localhost")
      assert route.plug == StreamixWeb.Router
    end

    test "preserves and encodes the search text", %{conn: conn} do
      conn = get(conn, "/gindex/movies", %{search: "ação & série", ignored: "value"})
      uri = conn |> redirected_to(302) |> URI.parse()
      assert uri.path == "/browse/movies"
      assert URI.decode_query(uri.query) == %{"source" => "gindex", "search" => "ação & série"}
    end

    test "empty search retains the original destination", %{conn: conn} do
      assert conn |> get("/gindex/movies?search=") |> redirected_to(302) ==
               "/browse/movies?source=gindex"
    end
  end

  test "legacy route still requires authentication", %{conn: conn} do
    assert conn |> get("/gindex/movies") |> redirected_to(302) == "/login"
  end
end
