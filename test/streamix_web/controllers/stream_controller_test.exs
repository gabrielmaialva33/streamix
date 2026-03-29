defmodule StreamixWeb.StreamControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.ConnTest

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias StreamixWeb.StreamToken

  test "global token with user but without subscription returns forbidden subscription error", %{
    conn: conn
  } do
    owner = user_fixture()
    user = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "global",
        is_system: true,
        url: "http://127.0.0.1:65535"
      })

    movie = movie_fixture(provider, %{stream_id: 91_337})
    token = StreamToken.sign_movie(movie.id, user.id)

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert json_response(conn, 403) == %{"error" => "Subscription required"}
  end

  test "url token falls back to a safe short GET and does not read the full body", %{conn: conn} do
    body_counter = start_supervised!({Agent, fn -> 0 end})
    server = start_stream_proxy_server(body_counter)
    {:ok, {address, port}} = ThousandIsland.listener_info(server)
    assert address == {127, 0, 0, 1}

    original_req_options = Application.get_env(:streamix, :stream_proxy_req_options)

    on_exit(fn ->
      case original_req_options do
        nil -> Application.delete_env(:streamix, :stream_proxy_req_options)
        value -> Application.put_env(:streamix, :stream_proxy_req_options, value)
      end
    end)

    Application.put_env(:streamix, :stream_proxy_req_options,
      connect_options: [timeout: 5_000, proxy: {:http, "127.0.0.1", port, []}]
    )

    token = StreamToken.sign_url("http://example.com/video.mp4", user_fixture().id)
    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert response(conn, 302) =~ "redirected"
    location = get_resp_header(conn, "location") |> List.first()
    assert String.contains?(location, "example.com")
    assert String.contains?(location, "video.mp4")
    assert Agent.get(body_counter, & &1) < 200
  end

  defp start_stream_proxy_server(body_counter) do
    start_supervised!({
      Bandit,
      plug: {Streamix.TestSupport.StreamProxyTestServer, body_counter: body_counter},
      scheme: :http,
      port: 0,
      ip: :loopback,
      startup_log: false
    })
  end
end
