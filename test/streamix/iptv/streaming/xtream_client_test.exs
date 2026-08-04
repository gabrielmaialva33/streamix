defmodule Streamix.Iptv.Streaming.XtreamClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Streaming.{ProviderRuntime, UpstreamPolicy}
  alias Streamix.Iptv.{XtreamCircuitBreaker, XtreamClient}

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
end
