defmodule Streamix.Gindex.TransportTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.Transport

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:streamix, Streamix.Gindex.Pacer)
    Application.put_env(:streamix, Streamix.Gindex.Pacer, gdrive: 1_000)

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, Streamix.Gindex.Pacer, original),
        else: Application.delete_env(:streamix, Streamix.Gindex.Pacer)
    end)

    :ok
  end

  test "retries an intermittent worker TypeError on the same endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sync.example.com"

      Plug.Conn.send_resp(
        conn,
        500,
        "TypeError: Cannot read properties of undefined (reading 'map')"
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sync.example.com"
      Plug.Conn.send_resp(conn, 200, ~s({"data":{"files":[]}}))
    end)

    base_url = "https://sync.example.com"

    assert {:ok, %{status: 200, body: ~s({"data":{"files":[]}})}} =
             Transport.request(
               :post,
               "#{base_url}/1:/Filmes/",
               ~s({"id":"","type":"folder","password":"","page_token":null,"page_index":0}),
               base_url,
               plug: {Req.Test, __MODULE__},
               server_error_delay_ms: 0
             )
  end

  test "keeps server-error and rate-limit retry budgets independent" do
    quota_counter = start_supervised!({Agent, fn -> 0 end})

    quota_fun = fn ->
      count = Agent.get_and_update(quota_counter, fn count -> {count + 1, count + 1} end)
      {:ok, :ok, count}
    end

    handler_id = "gindex-transport-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:streamix, :gindex, :request, :stop],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:request_outcome, metadata.outcome})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for {status, body} <- [
          {500, "TypeError: intermittent shard failure"},
          {503, "rate limited"},
          {500, "TypeError: another intermittent shard failure"},
          {200, ~s({"data":{"files":[]}})}
        ] do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, body) end)
    end

    base_url = "https://sync.example.com"

    assert {:ok, %{status: 200}} =
             Transport.request(
               :post,
               "#{base_url}/1:/Filmes/",
               ~s({"id":"","type":"folder","password":"","page_token":null,"page_index":0}),
               base_url,
               plug: {Req.Test, __MODULE__},
               quota_fun: quota_fun,
               server_error_delay_ms: 0,
               rate_limit_delay_ms: 0
             )

    assert Agent.get(quota_counter, & &1) == 4
    assert_receive {:request_outcome, :typeerror_skip}
    assert_receive {:request_outcome, :rate_limited}
    assert_receive {:request_outcome, :typeerror_skip}
    assert_receive {:request_outcome, :ok}
    refute_receive {:request_outcome, _outcome}
  end
end
