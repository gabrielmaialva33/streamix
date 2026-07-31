defmodule Streamix.Iptv.Streaming.VodProxyLivenessTest do
  use Streamix.DataCase, async: false

  import Plug.Test
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Channels
  alias Streamix.Iptv.LiveChannel
  alias Streamix.Iptv.Streaming.{ProviderRuntime, RedirectResolver, VodProxy}

  setup do
    RedirectResolver.clear_cache()
    ProviderRuntime.reset()

    on_exit(fn ->
      RedirectResolver.clear_cache()
      ProviderRuntime.reset()
    end)
  end

  test "marks a live channel dead on a terminal upstream 404 without poisoning provider health" do
    provider = global_provider_fixture()
    channel = channel_fixture(provider)
    port = start_proxy_server(:terminal)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
      provider_id: provider.id,
      content_id: channel.id,
      media_type: "channel"
    )

    assert Repo.get!(LiveChannel, channel.id).dead_since
    assert ProviderRuntime.snapshot(provider.id).dimensions.live.status == :unknown
  end

  test "clears a stale dead marker after successful channel playback" do
    provider = global_provider_fixture()
    channel = channel_fixture(provider)
    :ok = Channels.mark_dead(channel.id)
    assert Repo.get!(LiveChannel, channel.id).dead_since

    port = start_proxy_server(:ok)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
      provider_id: provider.id,
      content_id: channel.id,
      media_type: "channel"
    )

    refute Repo.get!(LiveChannel, channel.id).dead_since
    assert ProviderRuntime.snapshot(provider.id).dimensions.live.status == :healthy
  end

  defp start_proxy_server(mode) do
    counter = start_supervised!({Agent, fn -> 0 end})

    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StubPlug, mode: mode, counter: counter},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule StubPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      mode = Keyword.fetch!(opts, :mode)
      counter = Keyword.fetch!(opts, :counter)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      case {mode, request_number} do
        {:terminal, 1} -> send_resp(conn, 200, "resolver")
        {:terminal, _} -> send_resp(conn, 404, "missing")
        {:ok, 1} -> send_resp(conn, 200, "resolver")
        {:ok, _} -> send_resp(conn, 200, "stream-bytes")
      end
    end
  end
end
