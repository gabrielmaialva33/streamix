defmodule Streamix.Gindex.TransportTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.{HealthTracker, QuotaGuard, RequestBudget, Transport}

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

  test "keeps server-error retries independent from the request quota" do
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
               operation: :list,
               workload: :background
             )

    assert Agent.get(quota_counter, & &1) == 3
    assert_receive {:request_outcome, :typeerror_skip}
    assert_receive {:request_outcome, :typeerror_skip}
    assert_receive {:request_outcome, :ok}
    refute_receive {:request_outcome, _outcome}
  end

  test "returns upstream rate limits immediately and marks playback health unhealthy" do
    base_url = "https://rate-limited.example.com"
    endpoints = [{:stream, base_url, 1}]

    on_exit(fn -> HealthTracker.reset_all(endpoints) end)

    for _ <- 1..3 do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "17")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:error, {:rate_limited, 429, 17}} =
               Transport.request(
                 :post,
                 "#{base_url}/1:/Filmes/movie.mkv",
                 ~s({"id":"","type":"file","password":""}),
                 base_url,
                 plug: {Req.Test, __MODULE__},
                 quota_fun: fn :playback -> {:ok, :ok, 1} end,
                 operation: :stream,
                 workload: :playback
               )
    end

    refute HealthTracker.healthy?(base_url, :stream)
  end

  test "does not pin interactive playback behind transport retry sleeps" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Transport.request(
               :post,
               "https://stream.example.com/1:/Filmes/movie.mkv",
               ~s({"id":"","type":"file","password":""}),
               "https://stream.example.com",
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :playback -> {:ok, :ok, 1} end,
               operation: :stream,
               workload: :playback
             )
  end

  test "backs background work off for a canary window when 429 has no guidance" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "rate limited") end)

    assert {:error, {:rate_limited, 429, 900}} =
             Transport.request(
               :post,
               "https://sync.example.com/1:/Filmes/",
               ~s({"id":"","type":"folder","password":""}),
               "https://sync.example.com",
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :background -> {:ok, :ok, 1} end,
               operation: :list,
               workload: :background
             )
  end

  test "backs Cloudflare Worker Error 1027 off until the daily UTC reset" do
    base_url = "https://daily-limit.example.com"
    on_exit(fn -> HealthTracker.reset_all([{:stream, base_url, 1}]) end)

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 429, "error code: 1027")
    end)

    assert {:error, {:rate_limited, 429, retry_after}} =
             Transport.request(
               :post,
               "#{base_url}/1:/Filmes/movie.mkv",
               ~s({"id":"","type":"file","password":""}),
               base_url,
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :playback -> {:ok, :ok, 1} end,
               operation: :stream,
               workload: :playback
             )

    assert abs(retry_after - QuotaGuard.seconds_until_reset()) <= 2
  end

  test "stops a scan slice before consuming another global quota slot" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    quota_counter = start_supervised!({Agent, fn -> 0 end})

    quota_fun = fn ->
      Agent.update(quota_counter, &(&1 + 1))
      {:ok, :ok, Agent.get(quota_counter, & &1)}
    end

    request = fn ->
      Transport.request(:get, "https://sync.example.com/file", nil, "https://sync.example.com",
        plug: {Req.Test, __MODULE__},
        quota_fun: quota_fun
      )
    end

    RequestBudget.run(1, fn ->
      assert {:ok, %{status: 200}} = request.()
      assert {:error, {:slice_exhausted, 1}} = request.()
    end)

    assert Agent.get(quota_counter, & &1) == 1
  end
end
