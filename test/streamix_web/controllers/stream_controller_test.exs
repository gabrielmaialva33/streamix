defmodule StreamixWeb.StreamControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
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

    assert %{
             "error" => %{"code" => "subscription_required", "message" => "Subscription required"}
           } = json_response(conn, 403)
  end

  describe "X-API-Key bypasses subscription check" do
    setup do
      original_api_keys = Application.get_env(:streamix, :api_keys, [])
      Application.put_env(:streamix, :api_keys, ["stream-test-key"])
      on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)
      :ok
    end

    test "public-catalog token (user_id=nil) + valid X-API-Key skips subscription 403", %{
      conn: conn
    } do
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          # Non-routable address → upstream resolve will bad_gateway, but we
          # only care that auth passed.
          url: "http://127.0.0.1:65535"
        })

      movie = movie_fixture(provider, %{stream_id: 12_345})
      token = StreamToken.sign_movie(movie.id, nil)

      capture_log(fn ->
        conn =
          conn
          |> put_req_header("x-api-key", "stream-test-key")
          |> get("/api/stream/proxy?token=#{URI.encode_www_form(token)}")

        # The request MUST NOT be rejected as subscription_required.
        # Upstream resolve is expected to fail (bad_gateway) in the test setup,
        # which is fine — past the auth gate is past the auth gate.
        refute conn.status == 403
        refute conn.resp_body =~ "Subscription required"
      end)
    end

    test "same token WITHOUT X-API-Key still returns subscription_required", %{conn: conn} do
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          url: "http://127.0.0.1:65535"
        })

      movie = movie_fixture(provider, %{stream_id: 12_346})
      token = StreamToken.sign_movie(movie.id, nil)

      conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

      assert %{
               "error" => %{
                 "code" => "subscription_required",
                 "message" => "Subscription required"
               }
             } = json_response(conn, 403)
    end

    test "invalid X-API-Key does NOT bypass — still subscription_required", %{conn: conn} do
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          url: "http://127.0.0.1:65535"
        })

      movie = movie_fixture(provider, %{stream_id: 12_347})
      token = StreamToken.sign_movie(movie.id, nil)

      conn =
        conn
        |> put_req_header("x-api-key", "wrong-key")
        |> get("/api/stream/proxy?token=#{URI.encode_www_form(token)}")

      assert %{
               "error" => %{
                 "code" => "subscription_required",
                 "message" => "Subscription required"
               }
             } = json_response(conn, 403)
    end

    test "token signed with bypass_subscription=true skips auth without any header", %{
      conn: conn
    } do
      # This is the path that matters for source.mahina.cloud/proxy — the
      # intermediate proxy strips headers, but the token itself carries the
      # authorization claim (signed, so it can't be forged).
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          url: "http://127.0.0.1:65535"
        })

      movie = movie_fixture(provider, %{stream_id: 12_348})
      token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

      capture_log(fn ->
        conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

        # Past the subscription gate — upstream resolve fails (bad_gateway)
        # but that's expected in the test harness.
        refute conn.status == 403
        refute conn.resp_body =~ "Subscription required"
      end)
    end

    test "token WITHOUT bypass flag still requires subscription (no regression)", %{conn: conn} do
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          url: "http://127.0.0.1:65535"
        })

      movie = movie_fixture(provider, %{stream_id: 12_349})
      # Old-style token: no bypass flag, user_id=nil.
      token = StreamToken.sign_movie(movie.id, nil)

      conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

      assert %{
               "error" => %{
                 "code" => "subscription_required",
                 "message" => "Subscription required"
               }
             } = json_response(conn, 403)
    end
  end

  test "url token falls back to a safe short GET and does not read the full body", %{conn: conn} do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "public",
        is_system: false,
        url: "http://example.com"
      })

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

    token =
      StreamToken.sign_url("http://example.com/video.mp4", owner.id, provider_id: provider.id)

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert response(conn, 302) =~ "redirected"
    location = get_resp_header(conn, "location") |> List.first()
    assert String.contains?(location, "example.com")
    assert String.contains?(location, "video.mp4")
    assert Agent.get(body_counter, & &1) < 200
  end

  test "url token falls back to GET when upstream rejects HEAD but serves GET", %{conn: conn} do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "public",
        is_system: false,
        url: "http://example.com"
      })

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

    token =
      StreamToken.sign_url(
        "http://example.com/head-blocked.mp4",
        owner.id,
        provider_id: provider.id
      )

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert response(conn, 302) =~ "redirected"
    location = get_resp_header(conn, "location") |> List.first()
    assert String.contains?(location, "head-blocked.mp4")
    assert Agent.get(body_counter, & &1) < 200
  end

  test "url token allows final xtream url when redirecting through trusted proxy", %{conn: conn} do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "public",
        is_system: false,
        url: "http://example.com"
      })

    body_counter = start_supervised!({Agent, fn -> 0 end})
    server = start_stream_proxy_server(body_counter)
    {:ok, {address, port}} = ThousandIsland.listener_info(server)
    assert address == {127, 0, 0, 1}

    original_req_options = Application.get_env(:streamix, :stream_proxy_req_options)
    original_proxy_url = Application.get_env(:streamix, :stream_proxy_url)

    on_exit(fn ->
      case original_req_options do
        nil -> Application.delete_env(:streamix, :stream_proxy_req_options)
        value -> Application.put_env(:streamix, :stream_proxy_req_options, value)
      end

      case original_proxy_url do
        nil -> Application.delete_env(:streamix, :stream_proxy_url)
        value -> Application.put_env(:streamix, :stream_proxy_url, value)
      end
    end)

    Application.put_env(:streamix, :stream_proxy_req_options,
      connect_options: [timeout: 5_000, proxy: {:http, "127.0.0.1", port, []}]
    )

    Application.put_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

    token =
      StreamToken.sign_url(
        "http://example.com/redirect-to-xtream.mp4",
        owner.id,
        provider_id: provider.id
      )

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert response(conn, 302) =~ "redirected"

    location = get_resp_header(conn, "location") |> List.first()
    assert String.starts_with?(location, "https://source.mahina.cloud/proxy?url=")

    proxied_url =
      location
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("url")

    assert proxied_url == "http://cdn.example.test/movie/final_user/final_pass/99807.mp4"
  end

  test "url token follows get-only redirect chain before redirecting to trusted proxy", %{
    conn: conn
  } do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "public",
        is_system: false,
        url: "http://example.com"
      })

    body_counter = start_supervised!({Agent, fn -> 0 end})
    server = start_stream_proxy_server(body_counter)
    {:ok, {address, port}} = ThousandIsland.listener_info(server)
    assert address == {127, 0, 0, 1}

    original_req_options = Application.get_env(:streamix, :stream_proxy_req_options)
    original_proxy_url = Application.get_env(:streamix, :stream_proxy_url)

    on_exit(fn ->
      case original_req_options do
        nil -> Application.delete_env(:streamix, :stream_proxy_req_options)
        value -> Application.put_env(:streamix, :stream_proxy_req_options, value)
      end

      case original_proxy_url do
        nil -> Application.delete_env(:streamix, :stream_proxy_url)
        value -> Application.put_env(:streamix, :stream_proxy_url, value)
      end
    end)

    Application.put_env(:streamix, :stream_proxy_req_options,
      connect_options: [timeout: 5_000, proxy: {:http, "127.0.0.1", port, []}]
    )

    Application.put_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

    token =
      StreamToken.sign_url(
        "http://example.com/redirect-chain.mp4",
        owner.id,
        provider_id: provider.id
      )

    conn = get(conn, "/api/stream/proxy?token=#{URI.encode_www_form(token)}")

    assert response(conn, 302) =~ "redirected"

    location = get_resp_header(conn, "location") |> List.first()
    assert String.starts_with?(location, "https://source.mahina.cloud/proxy?url=")

    proxied_url =
      location
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("url")

    assert proxied_url == "http://cdn.example.test/deliver/redirect-chain.mp4"
    assert Agent.get(body_counter, & &1) < 10
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
