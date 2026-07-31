defmodule Streamix.Iptv.Streaming.LiveProxy do
  @moduledoc """
  Plug adapter for `StreamMultiplexer` live subscriptions.

  The controller process keeps at most one demanded chunk in its mailbox. After
  `Plug.Conn.chunk/2` accepts that chunk it asks for the next one, providing a
  bounded handoff between the shared upstream and each viewer socket.
  """

  alias Plug.Conn

  alias Streamix.Iptv.Streaming.{StreamErrors, VodProxy}
  alias Streamix.Iptv.StreamMultiplexer
  alias Streamix.SafeLog

  require Logger

  @ready_timeout 15_000
  @default_stream_idle_timeout 45_000
  @forwardable_headers ~w(content-type accept-ranges etag last-modified)

  @spec pipe(Conn.t(), String.t(), keyword()) :: Conn.t()
  def pipe(conn, url, opts \\ []) do
    urls = Keyword.get(opts, :url_chain, [url])
    stream_key = Keyword.get_lazy(opts, :stream_key, fn -> stream_key(url, opts) end)

    mux_opts =
      Keyword.take(opts, [
        :provider_id,
        :content_id,
        :buffer_size,
        :subscriber_buffer_bytes,
        :idle_timeout,
        :url_validator
      ])

    case StreamMultiplexer.subscribe(stream_key, urls, mux_opts) do
      {:ok, subscription} -> consume_subscription(conn, url, opts, subscription)
      {:error, :capacity_exhausted} -> StreamErrors.halt(conn, :provider_capacity_exhausted)
      {:error, reason} -> fallback_before_headers(conn, url, opts, reason)
    end
  end

  defp consume_subscription(conn, url, opts, %{pid: mux_pid} = subscription) do
    monitor_ref = Process.monitor(mux_pid)

    try do
      case ready_payload(subscription, mux_pid, monitor_ref) do
        {:ok, status, headers, backlog} ->
          conn
          |> send_live_headers(status, headers)
          |> send_backlog(backlog)
          |> consume_live(mux_pid, monitor_ref)

        {:error, :upstream_timeout} ->
          StreamErrors.halt(conn, :upstream_timeout)

        {:error, reason} ->
          await_mux_down(mux_pid, monitor_ref)
          fallback_before_headers(conn, url, opts, reason)
      end
    after
      StreamMultiplexer.unsubscribe(mux_pid)
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp ready_payload(
         %{status: :ready, response_status: status, headers: headers, backlog: backlog},
         _mux_pid,
         _monitor_ref
       ) do
    {:ok, status || 200, headers, backlog}
  end

  defp ready_payload(_subscription, mux_pid, monitor_ref) do
    receive do
      {:stream_mux, ^mux_pid, {:ready, status, headers, backlog}} ->
        {:ok, status, headers, backlog}

      {:stream_mux, ^mux_pid, {:error, reason}} ->
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^mux_pid, reason} ->
        {:error, {:multiplexer_down, reason}}
    after
      @ready_timeout -> {:error, :upstream_timeout}
    end
  end

  defp send_live_headers(conn, status, headers) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        normalized_name = String.downcase(name)

        if normalized_name in @forwardable_headers do
          Conn.put_resp_header(conn, normalized_name, value)
        else
          conn
        end
      end)

    conn
    |> ensure_content_type()
    |> Conn.put_resp_header("cache-control", "no-cache, no-store")
    |> Conn.put_resp_header("access-control-allow-origin", "*")
    |> Conn.put_resp_header("access-control-expose-headers", "Accept-Ranges, ETag, Last-Modified")
    |> Conn.send_chunked(status)
  end

  defp ensure_content_type(conn) do
    if Conn.get_resp_header(conn, "content-type") == [] do
      Conn.put_resp_header(conn, "content-type", "video/mp2t")
    else
      conn
    end
  end

  defp send_backlog(conn, backlog) do
    Enum.reduce_while(backlog, conn, fn chunk, conn ->
      case Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp consume_live({:error, conn}, _mux_pid, _monitor_ref), do: conn

  defp consume_live(conn, mux_pid, monitor_ref) do
    StreamMultiplexer.demand(mux_pid)
    receive_live(conn, mux_pid, monitor_ref)
  end

  defp receive_live(conn, mux_pid, monitor_ref) do
    receive do
      {:stream_mux, ^mux_pid, {:chunk, chunk}} ->
        case Conn.chunk(conn, chunk) do
          {:ok, conn} ->
            StreamMultiplexer.demand(mux_pid)
            receive_live(conn, mux_pid, monitor_ref)

          {:error, _reason} ->
            conn
        end

      {:stream_mux, ^mux_pid, :done} ->
        conn

      {:stream_mux, ^mux_pid, {:error, reason}} ->
        Logger.warning("[LiveProxy] multiplexer ended: #{SafeLog.redact_inspect(reason)}")
        conn

      {:DOWN, ^monitor_ref, :process, ^mux_pid, reason} ->
        Logger.warning("[LiveProxy] multiplexer down: #{SafeLog.redact_inspect(reason)}")
        conn
    after
      stream_idle_timeout() ->
        Logger.warning("[LiveProxy] no upstream data before idle timeout")
        conn
    end
  end

  defp fallback_before_headers(conn, url, opts, reason) do
    Logger.warning(
      "[LiveProxy] shared live path unavailable; using dedicated proxy: #{SafeLog.redact_inspect(reason)}"
    )

    VodProxy.pipe(conn, url, opts)
  end

  defp await_mux_down(mux_pid, monitor_ref) do
    if Process.alive?(mux_pid) do
      receive do
        {:DOWN, ^monitor_ref, :process, ^mux_pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp stream_key(url, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    content_id = Keyword.get(opts, :content_id)

    fallback_id =
      :crypto.hash(:sha256, url)
      |> binary_part(0, 12)
      |> Base.url_encode64(padding: false)

    {:live, provider_id, content_id || fallback_id}
  end

  defp stream_idle_timeout do
    Application.get_env(:streamix, :live_mux_stream_idle_timeout_ms, @default_stream_idle_timeout)
  end
end
