defmodule Streamix.Iptv.Streaming.XtreamClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.{Provider, XtreamCircuitBreaker, XtreamClient}
  alias Streamix.Iptv.Streaming.{ProviderEndpoints, ProviderRuntime, UpstreamPolicy}

  setup do
    ProviderRuntime.reset()
    XtreamCircuitBreaker.reset_all()

    on_exit(fn ->
      ProviderRuntime.reset()
      XtreamCircuitBreaker.reset_all()
    end)
  end

  test "tracks authenticated API traffic under the database provider id" do
    port = start_api_server()
    provider_id = 8_001

    assert {:ok, %{"user_info" => %{"auth" => 1}}} =
             XtreamClient.get_account_info(
               "http://127.0.0.1:#{port}",
               "test-user",
               "test-password",
               provider_id: provider_id,
               allow_private_network: true,
               max_retries: 0
             )

    assert_receive {:xtream_request, headers}
    assert {"user-agent", UpstreamPolicy.user_agent()} in headers

    assert [%{provider_id: ^provider_id, circuit_state: :closed, success_count: 1}] =
             XtreamCircuitBreaker.get_all_status()

    assert ProviderRuntime.snapshot(provider_id).dimensions.control.status == :healthy
  end

  test "blocks private provider URLs before opening a connection" do
    port = start_api_server()

    assert {:error, :unsafe_url} =
             XtreamClient.get_account_info(
               "http://127.0.0.1:#{port}",
               "test-user",
               "test-password",
               max_retries: 0
             )

    refute_receive {:xtream_request, _headers}
  end

  test "a multi-domain provider fails over once and records a single circuit outcome" do
    dead_port = start_dead_server()
    good_port = start_api_server()

    provider = %Provider{
      id: 8_002,
      url: "http://127.0.0.1:#{dead_port}",
      urls: ["http://127.0.0.1:#{good_port}"],
      username: "test-user",
      password: "test-password",
      provider_type: :xtream
    }

    assert {:ok, %{"user_info" => %{"auth" => 1}}} =
             XtreamClient.get_account_info(provider.url, provider.username, provider.password,
               provider: provider,
               provider_id: provider.id,
               allow_private_network: true,
               max_retries: 0
             )

    assert_receive :dead_hit
    assert_receive {:xtream_request, _headers}

    # The whole walk is one tracked call: one circuit success, no errors.
    assert [%{provider_id: 8_002, circuit_state: :closed, success_count: 1, error_count: 0}] =
             XtreamCircuitBreaker.get_all_status()

    # The dead domain was demoted; the next call starts at the live one.
    assert ProviderEndpoints.chain(provider) == [
             "http://127.0.0.1:#{good_port}",
             "http://127.0.0.1:#{dead_port}"
           ]

    assert {:ok, _} =
             XtreamClient.get_account_info(provider.url, provider.username, provider.password,
               provider: provider,
               provider_id: provider.id,
               allow_private_network: true,
               max_retries: 0
             )

    refute_receive :dead_hit, 200
    assert_receive {:xtream_request, _headers}
  end

  test "a 401 from the first domain does not fail over to the next" do
    unauthorized_port = start_status_server(401, :unauthorized)
    good_port = start_api_server()

    provider = %Provider{
      id: 8_003,
      url: "http://127.0.0.1:#{unauthorized_port}",
      urls: ["http://127.0.0.1:#{good_port}"],
      username: "test-user",
      password: "test-password",
      provider_type: :xtream
    }

    assert {:error, {:http_error, 401}} =
             XtreamClient.get_account_info(provider.url, provider.username, provider.password,
               provider: provider,
               provider_id: provider.id,
               allow_private_network: true,
               max_retries: 0
             )

    assert_receive {:status_request, :unauthorized}
    refute_receive {:xtream_request, _headers}, 100
  end

  test "a 5xx from the first domain fails over to the next" do
    failing_port = start_status_server(503, :failing)
    good_port = start_api_server()

    provider = %Provider{
      id: 8_004,
      url: "http://127.0.0.1:#{failing_port}",
      urls: ["http://127.0.0.1:#{good_port}"],
      username: "test-user",
      password: "test-password",
      provider_type: :xtream
    }

    assert {:ok, %{"user_info" => %{"auth" => 1}}} =
             XtreamClient.get_account_info(provider.url, provider.username, provider.password,
               provider: provider,
               provider_id: provider.id,
               allow_private_network: true,
               max_retries: 0
             )

    assert_receive {:status_request, :failing}
    assert_receive {:xtream_request, _headers}
  end

  test "a single-base provider keeps the existing behavior" do
    dead_port = start_dead_server()

    provider = %Provider{
      id: 8_005,
      url: "http://127.0.0.1:#{dead_port}",
      username: "test-user",
      password: "test-password",
      provider_type: :xtream
    }

    assert {:error, {:transport_error, _reason}} =
             XtreamClient.get_account_info(provider.url, provider.username, provider.password,
               provider: provider,
               provider_id: provider.id,
               allow_private_network: true,
               max_retries: 0
             )

    assert_receive :dead_hit
    refute_receive :dead_hit, 100
  end

  # A TCP listener that accepts and immediately closes: the client sees a
  # transport error, and each attempt is observable as a `:dead_hit`.
  defp start_dead_server do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept_loop(listen, parent) end)
    port
  end

  defp accept_loop(listen, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        send(parent, :dead_hit)
        :gen_tcp.close(socket)
        accept_loop(listen, parent)

      {:error, _reason} ->
        accept_loop(listen, parent)
    end
  end

  defp start_status_server(status, tag) do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StatusPlug, parent: self(), status: status, tag: tag},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp start_api_server do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.ApiPlug, parent: self()},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule ApiPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      send(Keyword.fetch!(opts, :parent), {:xtream_request, conn.req_headers})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"user_info" => %{"auth" => 1}}))
    end
  end

  defmodule StatusPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      send(Keyword.fetch!(opts, :parent), {:status_request, Keyword.fetch!(opts, :tag)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(Keyword.fetch!(opts, :status), "{}")
    end
  end
end
