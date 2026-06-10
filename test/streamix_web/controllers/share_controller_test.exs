defmodule StreamixWeb.ShareControllerTest do
  use StreamixWeb.ConnCase, async: true

  test "redirects shared title to search", %{conn: conn} do
    conn = get(conn, ~p"/share?title=Interstellar&text=&url=")
    assert redirected_to(conn) == "/search?q=Interstellar"
  end

  test "falls back to text, then url", %{conn: conn} do
    conn = get(conn, ~p"/share?text=O Menu")
    assert redirected_to(conn) == "/search?q=O+Menu"

    conn = get(conn, ~p"/share?url=https://example.com/movie")
    assert redirected_to(conn) == "/search?q=https%3A%2F%2Fexample.com%2Fmovie"
  end

  test "redirects to bare search when nothing useful was shared", %{conn: conn} do
    conn = get(conn, ~p"/share")
    assert redirected_to(conn) == "/search"
  end
end
