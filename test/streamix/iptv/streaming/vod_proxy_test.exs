defmodule Streamix.Iptv.Streaming.VodProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Streamix.Iptv.ProviderCapabilities
  alias Streamix.Iptv.Streaming.{ProviderRuntime, RedirectResolver, VodProxy}

  setup do
    RedirectResolver.clear_cache()
    ProviderRuntime.reset()
    attach_stream_proxy_telemetry()
    on_exit(&ProviderRuntime.reset/0)
  end

  test "rejects a stream before opening upstream when provider capacity is exhausted" do
    provider_id = 9001

    ProviderRuntime.put_capabilities(provider_id, %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      max_connections: 1
    })

    held_leases = acquire_leases(provider_id, :vod, 4)

    response =
      VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:1/never-opened",
        provider_id: provider_id,
        media_type: "movie"
      )

    assert response.status == 503

    assert %{"error" => %{"code" => "provider_capacity_exhausted", "retry_after" => 5}} =
             Jason.decode!(response.resp_body)

    Enum.each(held_leases, &ProviderRuntime.release/1)
  end

  test "serves a VOD HEAD probe without acquiring a provider lease" do
    port = start_proxy_server(:ok)
    provider_id = 9003

    ProviderRuntime.put_capabilities(provider_id, %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      max_connections: 1
    })

    held_leases = acquire_leases(provider_id, :vod, 4)

    response =
      VodProxy.head(conn(:head, "/proxy"), "http://127.0.0.1:#{port}/stream",
        provider_id: provider_id,
        media_type: "movie"
      )

    assert response.status == 200
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 4

    Enum.each(held_leases, &ProviderRuntime.release/1)
  end

  test "keeps provider lease admission for live HEAD probes" do
    provider_id = 9004

    ProviderRuntime.put_capabilities(provider_id, %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      max_connections: 1
    })

    assert {:ok, held_lease} = ProviderRuntime.acquire(provider_id, :live)

    response =
      VodProxy.head(conn(:head, "/proxy"), "http://127.0.0.1:1/never-opened",
        provider_id: provider_id,
        media_type: "channel"
      )

    assert response.status == 503
    ProviderRuntime.release(held_lease)
  end

  test "records provider and media identity without exposing the upstream URL" do
    port = start_proxy_server(:ok)
    provider_id = 9002

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
      provider_id: provider_id,
      content_id: 42,
      media_type: "movie"
    )

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :start], _, metadata}
    assert metadata.provider_id == provider_id
    assert metadata.content_id == 42
    assert metadata.media_type == "movie"
    refute Map.has_key?(metadata, :url)
    refute Map.has_key?(metadata, :final_url)

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], _, _}

    assert ProviderRuntime.snapshot(provider_id).dimensions.vod.status == :healthy
    assert ProviderRuntime.snapshot(provider_id).capacity.leased_connections == 0
  end

  test "emits start and completion telemetry with byte counts" do
    port = start_proxy_server(:ok)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :start], start,
                    start_meta}

    assert start.bytes_sent == 0
    assert start.retry_count == 0
    assert start.duration_ms >= 0
    assert start_meta.retry_count == 0

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    complete_meta}

    assert complete.bytes_sent == 6
    assert complete.retry_count == 0
    assert complete.duration_ms >= 0
    assert complete_meta == %{outcome: :ok, retry_count: 0}
  end

  test "emits upstream error and retry telemetry before successful completion" do
    port = start_proxy_server(:retry_once)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :start], _, _}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :upstream_error], error,
                    error_meta}

    assert error.bytes_sent == 0
    assert error.retry_count == 0
    assert error_meta.reason == {:unexpected_status, 503}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :upstream_retry], retry,
                    retry_meta}

    assert retry.bytes_sent == 0
    assert retry.retry_count == 1
    assert retry_meta.reason == {:unexpected_status, 503}
    assert retry_meta.retry_count == 1

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    complete_meta}

    assert complete.bytes_sent == 6
    assert complete.retry_count == 1
    assert complete_meta == %{outcome: :ok, retry_count: 1}
  end

  test "resumes an already chunked response without sending headers twice" do
    port = start_proxy_server(:disconnect_then_resume)

    response =
      VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")

    assert response.state == :chunked
    assert response.resp_body == "abcdefghijkl"

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :upstream_retry], retry,
                    %{
                      reason: %Finch.TransportError{
                        reason: :closed,
                        source: %Mint.TransportError{reason: :closed}
                      }
                    }}

    assert retry.bytes_sent == 6
    assert retry.retry_count == 1

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    %{outcome: :ok, retry_count: 1}}

    assert complete.bytes_sent == 12
  end

  @tag timeout: 60_000
  test "resets the retry budget after a failed burst resumes transferring bytes" do
    # The point of the test is that the window restarts once bytes flow again,
    # not how long the window is — so shrink it instead of stalling for 30 s.
    previous_budget = Application.get_env(:streamix, :vod_retry_budget_ms)
    Application.put_env(:streamix, :vod_retry_budget_ms, 1_000)

    on_exit(fn ->
      case previous_budget do
        nil -> Application.delete_env(:streamix, :vod_retry_budget_ms)
        value -> Application.put_env(:streamix, :vod_retry_budget_ms, value)
      end
    end)

    port = start_proxy_server(:failure_burst_then_progress)

    response =
      VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")

    assert response.state == :chunked
    assert response.resp_body == "abcdefghijkl"

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :upstream_retry], first,
                    %{reason: {:unexpected_status, 503}}}

    assert first.bytes_sent == 0
    assert first.retry_count == 1

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :upstream_retry], second,
                    _metadata}

    assert second.bytes_sent == 6
    assert second.retry_count == 2

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    %{outcome: :ok, retry_count: 2}}

    assert complete.bytes_sent == 12
  end

  test "emits terminal status telemetry without exposing upstream URL" do
    port = start_proxy_server(:terminal)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :start], _, _}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :terminal_status],
                    terminal, terminal_meta}

    assert terminal.bytes_sent == 0
    assert terminal.retry_count == 0
    assert terminal_meta == %{retry_count: 0, status: 404}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    complete_meta}

    assert complete.bytes_sent == 0
    assert complete.retry_count == 0
    assert complete_meta == %{outcome: :terminal_status, retry_count: 0, status: 404}

    refute_receive {:stream_proxy_telemetry, _event, _measurements, %{url: _url}}
    refute_receive {:stream_proxy_telemetry, _event, _measurements, %{final_url: _url}}
  end

  test "emits client closed telemetry when the downstream chunk fails" do
    port = start_proxy_server(:ok)
    conn = %{conn(:get, "/proxy") | adapter: {__MODULE__.ClosingAdapter, %{}}}

    VodProxy.pipe(conn, "http://127.0.0.1:#{port}/stream")

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :start], _, _}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :client_closed], closed,
                    closed_meta}

    assert closed.bytes_sent == 0
    assert closed.retry_count == 0
    assert closed_meta == %{retry_count: 0}

    assert_receive {:stream_proxy_telemetry, [:streamix, :stream_proxy, :complete], complete,
                    complete_meta}

    assert complete.bytes_sent == 0
    assert complete_meta == %{outcome: :client_closed, retry_count: 0}
  end

  test "redacts tokens nested inside resolver errors" do
    port = start_proxy_server(:invalid_query_redirect)

    log =
      capture_log(fn ->
        VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream")
      end)

    assert log =~ "invalid_request_target"
    assert log =~ "stream_id=3333506"
    assert log =~ "token=[REDACTED]"
    refute log =~ "top-secret"
  end

  defp attach_stream_proxy_telemetry do
    test_pid = self()
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    events =
      for event <- [
            :start,
            :client_closed,
            :upstream_error,
            :upstream_retry,
            :terminal_status,
            :complete
          ] do
        [:streamix, :stream_proxy, event]
      end

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:stream_proxy_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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

  defp acquire_leases(provider_id, traffic_class, count) do
    for _index <- 1..count do
      assert {:ok, lease} = ProviderRuntime.acquire(provider_id, traffic_class)
      lease
    end
  end

  defmodule StubPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      mode = Keyword.fetch!(opts, :mode)
      counter = Keyword.fetch!(opts, :counter)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      handle_request(conn, mode, request_number)
    end

    defp handle_request(conn, :ok, _request_number), do: send_resp(conn, 200, "abcdef")

    defp handle_request(conn, :retry_once, 1), do: send_resp(conn, 200, "resolver")
    defp handle_request(conn, :retry_once, 2), do: send_resp(conn, 503, "temporary")
    defp handle_request(conn, :retry_once, _request_number), do: send_resp(conn, 200, "abcdef")

    defp handle_request(conn, :disconnect_then_resume, 1), do: send_resp(conn, 200, "resolver")

    defp handle_request(conn, :disconnect_then_resume, 2) do
      conn =
        conn
        |> put_resp_header("content-type", "video/mp4")
        |> send_chunked(200)

      {:ok, _conn} = chunk(conn, "abcdef")
      Process.exit(self(), :kill)
    end

    defp handle_request(conn, :disconnect_then_resume, _request_number) do
      case get_req_header(conn, "range") do
        ["bytes=6-"] ->
          conn
          |> put_resp_header("content-type", "video/mp4")
          |> put_resp_header("content-range", "bytes 6-11/12")
          |> send_resp(206, "ghijkl")

        _other ->
          send_resp(conn, 400, "missing range")
      end
    end

    defp handle_request(conn, :failure_burst_then_progress, 1),
      do: send_resp(conn, 200, "resolver")

    defp handle_request(conn, :failure_burst_then_progress, 2),
      do: send_resp(conn, 503, "temporary")

    defp handle_request(conn, :failure_burst_then_progress, 3) do
      conn =
        conn
        |> put_resp_header("content-type", "video/mp4")
        |> send_chunked(200)

      {:ok, _conn} = chunk(conn, "abcdef")

      # Outlast the (shrunken) retry window so the resume proves the window
      # restarted rather than never having been exceeded.
      receive do
      after
        1_200 -> Process.exit(self(), :kill)
      end
    end

    defp handle_request(conn, :failure_burst_then_progress, _request_number) do
      case get_req_header(conn, "range") do
        ["bytes=6-"] ->
          conn
          |> put_resp_header("content-type", "video/mp4")
          |> put_resp_header("content-range", "bytes 6-11/12")
          |> send_resp(206, "ghijkl")

        _other ->
          send_resp(conn, 400, "missing range")
      end
    end

    defp handle_request(conn, :terminal, 1), do: send_resp(conn, 200, "resolver")
    defp handle_request(conn, :terminal, _request_number), do: send_resp(conn, 404, "missing")

    defp handle_request(conn, :invalid_query_redirect, _request_number) do
      conn
      |> put_resp_header(
        "location",
        "http://#{conn.host}:#{conn.port}/video.mp4" <>
          "?stream_id=3333506&token=top-secret&label=bad value"
      )
      |> send_resp(302, "")
    end
  end

  defmodule ClosingAdapter do
    @moduledoc false

    def send_chunked(payload, _status, _headers), do: {:ok, "", payload}
    def chunk(_payload, _body), do: {:error, :closed}
  end
end
