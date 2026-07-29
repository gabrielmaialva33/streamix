defmodule Streamix.Iptv.Streaming.UpstreamPumpTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Streaming.UpstreamPump

  test "reports stalled consumers without taking down the caller" do
    port = start_chunk_server()
    req = Finch.build(:get, "http://127.0.0.1:#{port}/stream")

    pump =
      UpstreamPump.start(req, Streamix.StreamFinch, self(),
        cap_bytes: 1,
        receive_timeout: 1_000,
        pool_timeout: 1_000,
        ack_timeout: 50
      )

    assert_receive {pid, {:status, 200}} when pid == pump.pid
    assert_receive {pid, {:headers, _headers}} when pid == pump.pid
    assert_receive {pid, {:data, _chunk, size}} when pid == pump.pid and size > 1

    assert_receive {pid, {:error, {:pump_idle, _in_flight, 1}}} when pid == pump.pid
    assert_receive {:DOWN, ref, :process, pid, :normal} when ref == pump.ref and pid == pump.pid

    assert Process.alive?(self())
  end

  test "reports Finch transport errors with the streaming accumulator removed" do
    req = Finch.build(:get, "http://127.0.0.1:1/unreachable")

    pump =
      UpstreamPump.start(req, Streamix.StreamFinch, self(),
        receive_timeout: 500,
        pool_timeout: 500
      )

    assert_receive {pid, {:error, %Finch.TransportError{reason: :econnrefused}}}
                   when pid == pump.pid,
                   2_000

    assert_receive {:DOWN, ref, :process, pid, :normal} when ref == pump.ref and pid == pump.pid
  end

  defp start_chunk_server do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: __MODULE__.StubPlug, scheme: :http, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule StubPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, String.duplicate("x", 16))
      conn
    end
  end
end
