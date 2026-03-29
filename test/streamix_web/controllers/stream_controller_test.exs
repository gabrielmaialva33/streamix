defmodule StreamixWeb.StreamControllerTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.ConnTest

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias StreamixWeb.StreamToken

  test "global token without subscription returns forbidden subscription error", %{conn: conn} do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "global",
        is_system: true,
        url: "http://127.0.0.1:65535"
      })

    movie = movie_fixture(provider, %{stream_id: 91_337})
    token = StreamToken.sign_movie(movie.id, nil)

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert json_response(conn, 403) == %{"error" => "Subscription required"}
  end
end
