defmodule StreamixWeb.RouterPerformanceTest do
  use StreamixWeb.ConnCase, async: true

  import Streamix.IptvFixtures

  test "regular pages do not preconnect to the stream proxy", %{conn: conn} do
    conn = get(conn, ~p"/login")

    refute stream_proxy_hint?(conn)
  end

  test "speculative prefetch is CSP-authorized and limited to catalog navigation", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)
    [_, nonce] = Regex.run(~r/<script type="speculationrules" nonce="([^"]+)"/, html)
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "'nonce-#{nonce}'"
    assert html =~ ~s("href_matches":"/browse/*")
    refute html =~ ~s("href_matches":"/*")
  end

  test "authenticated home has its own in-session route", %{conn: conn} do
    user = Streamix.AccountsFixtures.user_fixture()

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/home")
      |> html_response(200)

    assert html =~ ~s(data-loading-home="true")
  end

  test "authenticated home route remains protected", %{conn: conn} do
    conn = get(conn, ~p"/home")

    assert redirected_to(conn) == ~p"/login"
  end

  test "unauthenticated player redirects do not preconnect to the stream proxy", %{conn: conn} do
    conn = get(conn, "/watch/movie/1")

    refute stream_proxy_hint?(conn)
  end

  test "authenticated player pages preconnect to the stream proxy", %{conn: conn} do
    user = Streamix.AccountsFixtures.user_fixture()
    provider = provider_fixture(user, %{visibility: "private", is_system: false})
    movie = movie_fixture(provider)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/watch/movie/#{movie.id}")

    assert stream_proxy_hint?(conn)
  end

  defp stream_proxy_hint?(conn) do
    proxy = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

    conn
    |> get_resp_header("link")
    |> Enum.any?(&String.contains?(&1, "<#{proxy}>; rel=preconnect"))
  end
end
