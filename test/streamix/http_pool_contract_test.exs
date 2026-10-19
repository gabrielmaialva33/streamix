defmodule Streamix.HttpPoolContractTest do
  # Pins a behaviour of the HTTP stack (Req -> Finch -> Mint) that every
  # upstream client relies on: after a receive timeout, the late response of
  # the abandoned request must never reach the next request on the pool.
  #
  # Mint 1.11 stopped closing the connection on a receive timeout. Finch 0.23
  # then returned that connection to the pool, so the next request read the
  # abandoned response and crashed with
  # `CaseClauseError {:status, stale_ref, 200}` — in production the GIndex
  # movie scan failed this way for weeks. Finch 0.24 closes the connection.
  use ExUnit.Case, async: true

  defmodule SlowThenFast do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%{request_path: "/slow"} = conn, test_pid) do
      send(test_pid, {:slow_waiting, self()})

      receive do
        :release -> send_resp(conn, 200, "late")
      end
    end

    def call(conn, _test_pid), do: send_resp(conn, 200, "fast")
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {SlowThenFast, self()}, scheme: :http, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # One connection, so the second request has to reuse whatever the first
    # one left in the pool.
    finch = __MODULE__.Finch
    start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})

    %{base: "http://127.0.0.1:#{port}", finch: finch}
  end

  test "a late response after a receive timeout never reaches the next request", ctx do
    assert {:error, %Req.TransportError{reason: :timeout}} =
             Req.get("#{ctx.base}/slow",
               finch: [name: ctx.finch],
               receive_timeout: 100,
               retry: false
             )

    assert_receive {:slow_waiting, handler}
    send(handler, :release)

    assert {:ok, %Req.Response{status: 200, body: "fast"}} =
             Req.get("#{ctx.base}/fast", finch: [name: ctx.finch], retry: false)
  end
end
