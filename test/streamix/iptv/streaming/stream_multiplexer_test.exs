defmodule Streamix.Iptv.StreamMultiplexerTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.ProviderCapabilities
  alias Streamix.Iptv.Streaming.{LiveProxy, ProviderRuntime}
  alias Streamix.Iptv.StreamMultiplexer

  setup do
    ProviderRuntime.reset()
    on_exit(&ProviderRuntime.reset/0)
  end

  test "fans one upstream request out to two demand-driven subscribers" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_001

    ProviderRuntime.put_capabilities(provider_id, capabilities(1))

    stream_key = {:mux_test, System.unique_integer([:positive])}
    url = "http://127.0.0.1:#{port}/live"

    assert {:ok, first} =
             StreamMultiplexer.subscribe(stream_key, url,
               provider_id: provider_id,
               idle_timeout: 0,
               url_validator: &allow_test_url/1
             )

    mux_pid = first.pid
    mux_monitor = Process.monitor(mux_pid)
    assert_receive {:upstream_ready, handler_pid}
    assert {:ok, 200, _headers, []} = await_ready(first)

    send(handler_pid, {:chunk, "one"})
    assert_receive {:upstream_chunked, "one"}
    StreamMultiplexer.demand(mux_pid)
    assert_receive {:stream_mux, ^mux_pid, {:chunk, "one"}}

    viewer = start_viewer(self(), stream_key, url, provider_id)

    assert_receive {:viewer_subscribed, ^viewer, {:ok, second}}
    assert second.pid == mux_pid
    assert second.status == :ready
    assert second.backlog == ["one"]
    assert Agent.get(counter, & &1) == 1

    StreamMultiplexer.demand(mux_pid)
    send(viewer, {:demand, mux_pid})
    send(handler_pid, {:chunk, "two"})
    assert_receive {:upstream_chunked, "two"}

    assert_receive {:stream_mux, ^mux_pid, {:chunk, "two"}}
    assert_receive {:viewer_message, ^viewer, {:stream_mux, ^mux_pid, {:chunk, "two"}}}

    StreamMultiplexer.demand(mux_pid)
    send(viewer, {:demand, mux_pid})
    send(handler_pid, :done)

    assert_receive {:stream_mux, ^mux_pid, :done}
    assert_receive {:viewer_message, ^viewer, {:stream_mux, ^mux_pid, :done}}
    assert_receive {:DOWN, ^mux_monitor, :process, ^mux_pid, :normal}

    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 0
    assert ProviderRuntime.snapshot(provider_id).dimensions.live.status == :healthy

    send(viewer, :stop)
  end

  test "frees the registry name promptly after the upstream ends cleanly" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_012
    stream_key = {:terminal_grace_test, System.unique_integer([:positive])}
    url = "http://127.0.0.1:#{port}/live"

    assert {:ok, subscription} =
             StreamMultiplexer.subscribe(stream_key, url,
               provider_id: provider_id,
               # A long live grace must not keep a finished stream around.
               idle_timeout: 60_000,
               url_validator: &allow_test_url/1
             )

    mux_pid = subscription.pid
    mux_monitor = Process.monitor(mux_pid)
    assert_receive {:upstream_ready, handler_pid}
    assert {:ok, 200, _headers, []} = await_ready(subscription)

    # Terminal events are demand-driven like chunks, so ask before ending.
    StreamMultiplexer.demand(mux_pid)
    send(handler_pid, :done)
    assert_receive {:stream_mux, ^mux_pid, :done}
    StreamMultiplexer.unsubscribe(mux_pid)

    # Without the terminal cap the process would sit on the registry name for
    # the full 60s grace, answering :stream_ended to everyone who arrived in
    # that window. Registry unregisters on process death, so the prompt exit
    # is what frees the name.
    assert_receive {:DOWN, ^mux_monitor, :process, ^mux_pid, :normal}, 3_000
  end

  test "reclaims an idle multiplexer when another channel needs the last lease" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_010
    ProviderRuntime.put_capabilities(provider_id, capabilities(1))
    base = System.unique_integer([:positive])

    assert {:ok, first} =
             StreamMultiplexer.subscribe({:reclaim_a, base}, "http://127.0.0.1:#{port}/live/a",
               provider_id: provider_id,
               idle_timeout: 60_000,
               url_validator: &allow_test_url/1
             )

    first_pid = first.pid
    first_monitor = Process.monitor(first_pid)
    assert_receive {:upstream_ready, first_handler}
    assert {:ok, 200, _headers, []} = await_ready(first)

    # The last viewer leaves: the upstream stays open for the grace period and
    # keeps the provider's only lease.
    StreamMultiplexer.unsubscribe(first_pid)
    assert map_size(:sys.get_state(first_pid).subscribers) == 0
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 1

    assert {:ok, second} =
             StreamMultiplexer.subscribe({:reclaim_b, base}, "http://127.0.0.1:#{port}/live/b",
               provider_id: provider_id,
               idle_timeout: 0,
               url_validator: &allow_test_url/1
             )

    refute second.pid == first_pid
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :normal}
    assert_receive {:upstream_ready, second_handler}
    assert {:ok, 200, _headers, []} = await_ready(second)
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 1
    assert Agent.get(counter, & &1) == 2

    send(first_handler, :done)
    send(second_handler, :done)
  end

  test "never reclaims a multiplexer that still has a viewer" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_011
    ProviderRuntime.put_capabilities(provider_id, capabilities(1))
    base = System.unique_integer([:positive])

    assert {:ok, first} =
             StreamMultiplexer.subscribe({:busy_a, base}, "http://127.0.0.1:#{port}/live/a",
               provider_id: provider_id,
               idle_timeout: 60_000,
               url_validator: &allow_test_url/1
             )

    first_pid = first.pid
    assert_receive {:upstream_ready, first_handler}
    assert {:ok, 200, _headers, []} = await_ready(first)

    assert {:error, :capacity_exhausted} =
             StreamMultiplexer.subscribe({:busy_b, base}, "http://127.0.0.1:#{port}/live/b",
               provider_id: provider_id,
               idle_timeout: 0,
               url_validator: &allow_test_url/1
             )

    assert Process.alive?(first_pid)
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 1
    assert Agent.get(counter, & &1) == 1

    send(first_handler, :done)
  end

  test "disconnects a slow subscriber when its bounded queue is full" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_002
    stream_key = {:slow_mux_test, System.unique_integer([:positive])}

    assert {:ok, subscription} =
             StreamMultiplexer.subscribe(
               stream_key,
               "http://127.0.0.1:#{port}/live",
               provider_id: provider_id,
               subscriber_buffer_bytes: 3,
               idle_timeout: 0,
               url_validator: &allow_test_url/1
             )

    mux_pid = subscription.pid
    mux_monitor = Process.monitor(mux_pid)
    assert_receive {:upstream_ready, handler_pid}
    assert {:ok, 200, _headers, []} = await_ready(subscription)

    # No demand: four queued bytes exceed this subscriber's three-byte cap.
    send(handler_pid, {:chunk, "four"})
    assert_receive {:upstream_chunked, "four"}
    assert_receive {:stream_mux, ^mux_pid, {:error, :slow_consumer}}
    assert_receive {:DOWN, ^mux_monitor, :process, ^mux_pid, :normal}

    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 0
    send(handler_pid, :done)
  end

  test "keeps a slow subscriber on the newest bounded live data" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    provider_id = 7_003
    stream_key = {:catch_up_mux_test, System.unique_integer([:positive])}

    assert {:ok, subscription} =
             StreamMultiplexer.subscribe(
               stream_key,
               "http://127.0.0.1:#{port}/live",
               provider_id: provider_id,
               subscriber_buffer_bytes: 4,
               idle_timeout: 0,
               url_validator: &allow_test_url/1
             )

    mux_pid = subscription.pid
    mux_monitor = Process.monitor(mux_pid)
    assert_receive {:upstream_ready, handler_pid}
    assert {:ok, 200, _headers, []} = await_ready(subscription)

    send(handler_pid, {:chunk, "old"})
    assert_receive {:upstream_chunked, "old"}
    send(handler_pid, {:chunk, "new"})
    assert_receive {:upstream_chunked, "new"}

    refute_receive {:stream_mux, ^mux_pid, {:error, :slow_consumer}}
    assert Process.alive?(mux_pid)

    StreamMultiplexer.demand(mux_pid)
    assert_receive {:stream_mux, ^mux_pid, {:chunk, "new"}}

    StreamMultiplexer.demand(mux_pid)
    send(handler_pid, :done)
    assert_receive {:stream_mux, ^mux_pid, :done}
    assert_receive {:DOWN, ^mux_monitor, :process, ^mux_pid, :normal}
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 0
  end

  test "LiveProxy drains the shared stream into a chunked Plug response" do
    counter = start_supervised!({Agent, fn -> 0 end})
    port = start_live_server(counter)
    url = "http://127.0.0.1:#{port}/live"

    task =
      Task.async(fn ->
        LiveProxy.pipe(Plug.Test.conn(:get, "/proxy"), url,
          idle_timeout: 0,
          url_validator: &allow_test_url/1
        )
      end)

    assert_receive {:upstream_ready, handler_pid}
    send(handler_pid, {:chunk, "one"})
    assert_receive {:upstream_chunked, "one"}
    send(handler_pid, {:chunk, "two"})
    assert_receive {:upstream_chunked, "two"}
    send(handler_pid, :done)

    response = Task.await(task, 5_000)

    assert response.status == 200
    assert response.state == :chunked
    assert response.resp_body == "onetwo"
    assert Agent.get(counter, & &1) == 1
  end

  defp await_ready(%{status: :ready} = subscription) do
    {:ok, subscription.response_status, subscription.headers, subscription.backlog}
  end

  defp await_ready(%{pid: mux_pid}) do
    receive do
      {:stream_mux, ^mux_pid, {:ready, status, headers, backlog}} ->
        {:ok, status, headers, backlog}
    after
      2_000 -> {:error, :ready_timeout}
    end
  end

  defp start_viewer(parent, stream_key, url, provider_id) do
    spawn(fn ->
      result =
        StreamMultiplexer.subscribe(stream_key, url,
          provider_id: provider_id,
          idle_timeout: 0,
          url_validator: &allow_test_url/1
        )

      send(parent, {:viewer_subscribed, self(), result})
      viewer_loop(parent)
    end)
  end

  defp viewer_loop(parent) do
    receive do
      {:demand, mux_pid} ->
        StreamMultiplexer.demand(mux_pid)
        viewer_loop(parent)

      :stop ->
        :ok

      message ->
        send(parent, {:viewer_message, self(), message})
        viewer_loop(parent)
    end
  end

  defp start_live_server(counter) do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.LivePlug, parent: self(), counter: counter},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp capabilities(max_connections) do
    %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      max_connections: max_connections,
      active_connections: 0
    }
  end

  defp allow_test_url(_url), do: :ok

  defmodule LivePlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      parent = Keyword.fetch!(opts, :parent)
      counter = Keyword.fetch!(opts, :counter)
      Agent.update(counter, &(&1 + 1))

      conn = send_chunked(conn, 200)
      send(parent, {:upstream_ready, self()})
      stream(conn, parent)
    end

    defp stream(conn, parent) do
      receive do
        {:chunk, chunk} ->
          {:ok, conn} = chunk(conn, chunk)
          send(parent, {:upstream_chunked, chunk})
          stream(conn, parent)

        :done ->
          conn
      end
    end
  end
end
