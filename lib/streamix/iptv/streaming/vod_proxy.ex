defmodule Streamix.Iptv.Streaming.VodProxy do
  @moduledoc """
  BEAM-side reverse proxy for IPTV VOD/Live streams.

  Pumps upstream bytes into a `Plug.Conn` via `Finch.stream/5` +
  `Plug.Conn.chunk/2`. Provider credentials stay server-side, the
  Finch keepalive pool reuses TCP between Range requests, and a
  mid-stream upstream failure is recovered with a Range-aware retry
  instead of erroring the player out.

  ## Invariants

    * `Connection: close` is sent to the provider so it releases its
      slot when the stream ends — pooled idle connections trip
      `max_connections=1` quotas and trigger 509s.
    * 4xx is terminal (creds bad, channel gone). 5xx + I/O errors
      are transient and retried within a 5 s budget, at most 5
      attempts, 250 ms backoff.
    * A mid-stream retry re-issues the request with
      `Range: bytes=N-`. If the upstream answers 200 instead of 206
      we abort — restarted bytes from offset 0 would corrupt the
      decoder.
    * Retry only fires for media streams, never for short responses.

  ## Flow

      client GET /api/stream/proxy?token=…
        → StreamController.proxy/2
        → StreamToken.verify_and_get_url/2 — yields the upstream URL
        → VodProxy.pipe(conn, upstream_url)
        → RedirectResolver.resolve/2 — walks the vauth → deliver chain
        → Finch.stream/5 — pipes bytes into Plug.Conn.chunk/2
  """

  alias Plug.Conn
  alias Streamix.Iptv.Streaming.RedirectResolver
  alias StreamixWeb.StreamErrors

  require Logger

  # XCIPTV/VLC user-agents are whitelisted by most IPTV providers; the
  # BEAM's default `Req/...` UA gets bounced by the WAF.
  @upstream_user_agent "VLC/3.0.20 LibVLC/3.0.20"

  # Headers we forward verbatim from the player to the upstream so seek,
  # cache validation and conditional GETs all work end-to-end.
  @forwardable_request_headers ~w(range if-range if-none-match if-modified-since)

  # Headers we copy from the upstream response back to the player. These
  # are what hls.js / mpegts.js / mp4box.js need to drive playback,
  # validate cache and surface seek bars.
  @forwardable_response_headers ~w(
    content-type content-length content-range accept-ranges
    last-modified etag
  )

  # Mid-stream retry budget. After this many attempts (or this many ms
  # since the original request, whichever fires first) we give up and
  # let the player surface the error itself.
  @max_mid_stream_retries 5
  @retry_budget_ms 5_000
  @retry_backoff_ms 250

  # Hard ceiling on how long the upstream is allowed to stall after we
  # already started streaming. Past this we close the upstream socket
  # and ask the retry loop for a fresh chain.
  @upstream_idle_timeout_ms 30_000

  # Status codes we treat as terminal — retrying won't help.
  @terminal_statuses [400, 401, 403, 404, 405, 410, 416, 451]

  @doc """
  Resolves the vauth chain and pumps upstream bytes into `conn` via
  chunked encoding.

  Returns the (potentially halted) `Plug.Conn`. Errors during the
  initial chain resolution short-circuit before any bytes are sent
  and emit one of the canonical `StreamErrors` codes; mid-stream
  failures degrade gracefully — the conn finishes with whatever was
  already delivered.
  """
  @spec pipe(Conn.t(), String.t()) :: Conn.t()
  def pipe(conn, url) do
    state = %{
      original_url: url,
      bytes_sent: 0,
      retry_count: 0,
      started_at: System.monotonic_time(:millisecond)
    }

    case resolve_chain(url) do
      {:ok, final_url} ->
        do_pipe(conn, final_url, state)

      {:error, reason} ->
        Logger.warning("[VodProxy] resolve failed for #{sanitize(url)}: #{inspect(reason)}")
        StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
    end
  end

  defp resolve_chain(url) do
    # Walk the full vauth → … → deliver chain so Finch lands on a URL
    # that responds with 200/206. Stopping at the first non-creds hop
    # would still leave us on a 302 redirector and the pre-flight
    # would bounce.
    RedirectResolver.resolve(url, stop_fn: fn _ -> false end)
  end

  defp do_pipe(conn, _final_url, %{retry_count: n} = state)
       when n > @max_mid_stream_retries do
    Logger.warning("[VodProxy] giving up after #{n} retries for #{sanitize(state.original_url)}")

    conn
  end

  defp do_pipe(conn, final_url, state) do
    if exceeded_retry_budget?(state) do
      Logger.warning("[VodProxy] retry budget exhausted for #{sanitize(state.original_url)}")
      conn
    else
      do_pipe_attempt(conn, final_url, state)
    end
  end

  defp do_pipe_attempt(conn, final_url, state) do
    headers = build_request_headers(conn, state.bytes_sent)
    req = Finch.build(:get, final_url, headers)

    handle_attempt_result(stream_via_finch(conn, req, state), conn, state)
  end

  defp handle_attempt_result({:ok, conn, _final_state}, _conn, _state), do: conn
  defp handle_attempt_result({:error, :client_closed}, conn, _state), do: conn

  defp handle_attempt_result({:error, :before_first_byte, reason}, conn, state) do
    handle_pre_flight_error(conn, reason, state)
  end

  defp handle_attempt_result(
         {:error, {:after_chunk, chunked_conn, total_sent}, reason},
         _conn,
         state
       ) do
    handle_mid_stream_error(chunked_conn, total_sent, reason, state)
  end

  defp handle_attempt_result({:error, :status_terminal, status}, conn, _state) do
    Logger.warning("[VodProxy] terminal upstream status #{status}")
    StreamErrors.halt(conn, StreamErrors.code_from_reason({:unexpected_status, status}))
  end

  defp handle_attempt_result({:error, :status_no_partial, status}, conn, _state) do
    Logger.warning("[VodProxy] reconnect aborted: upstream ignored Range and returned #{status}")

    conn
  end

  defp handle_pre_flight_error(conn, reason, state) do
    if retryable_pre_flight_error?(reason) and state.retry_count < @max_mid_stream_retries do
      Logger.info(
        "[VodProxy] pre-flight failure (#{inspect(reason)}); retry #{state.retry_count + 1}"
      )

      retry_with_fresh_chain(conn, %{state | retry_count: state.retry_count + 1})
    else
      Logger.warning("[VodProxy] upstream pre-flight failed: #{inspect(reason)}")
      StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
    end
  end

  defp handle_mid_stream_error(chunked_conn, total_sent, reason, state) do
    if state.retry_count < @max_mid_stream_retries do
      Logger.warning(
        "[VodProxy] mid-stream upstream failure (#{inspect(reason)}); resume @ byte #{total_sent}; retry #{state.retry_count + 1}"
      )

      state = %{state | bytes_sent: total_sent, retry_count: state.retry_count + 1}
      retry_with_fresh_chain(chunked_conn, state)
    else
      chunked_conn
    end
  end

  defp retry_with_fresh_chain(conn, state) do
    Process.sleep(@retry_backoff_ms)

    case resolve_chain(state.original_url) do
      {:ok, fresh_url} ->
        do_pipe(conn, fresh_url, state)

      {:error, _} ->
        conn
    end
  end

  defp retryable_pre_flight_error?({:unexpected_status, status})
       when status in @terminal_statuses,
       do: false

  defp retryable_pre_flight_error?({:unexpected_status, _status}), do: true
  defp retryable_pre_flight_error?(:empty_upstream), do: true
  defp retryable_pre_flight_error?(%Mint.TransportError{}), do: true
  defp retryable_pre_flight_error?(:idle_timeout), do: true
  defp retryable_pre_flight_error?(_), do: false

  defp exceeded_retry_budget?(state) do
    System.monotonic_time(:millisecond) - state.started_at > @retry_budget_ms and
      state.retry_count > 0
  end

  # Streams the upstream into the conn. Returns `{:ok, conn, state}` on
  # a clean upstream EOF (or client-initiated halt) and `{:error, …}`
  # for the failure modes the caller knows how to recover from.
  defp stream_via_finch(conn, req, state) do
    initial = %{
      conn: conn,
      status: nil,
      sent_headers?: false,
      bytes_sent: state.bytes_sent,
      total_sent: state.bytes_sent,
      attempting_resume?: state.bytes_sent > 0
    }

    Finch.stream(req, Streamix.Finch, initial, &handle_chunk/2,
      receive_timeout: @upstream_idle_timeout_ms,
      pool_timeout: 5_000
    )
    |> case do
      {:ok, %{conn: conn, sent_headers?: true} = acc} ->
        {:ok, conn, acc}

      {:ok, %{sent_headers?: false}} ->
        {:error, :before_first_byte, :empty_upstream}

      {:error, reason} ->
        if initial.sent_headers? do
          {:error, {:after_chunk, initial.conn, initial.total_sent}, reason}
        else
          {:error, :before_first_byte, reason}
        end
    end
  catch
    {:client_closed, _} ->
      {:error, :client_closed}

    {:upstream_error, status, %{sent_headers?: false}} ->
      cond do
        status in @terminal_statuses ->
          {:error, :status_terminal, status}

        status in 400..499 ->
          {:error, :before_first_byte, {:unexpected_status, status}}

        status in 500..599 ->
          {:error, :before_first_byte, {:unexpected_status, status}}

        true ->
          {:error, :before_first_byte, {:unexpected_status, status}}
      end

    {:upstream_error, status, %{conn: conn, total_sent: total_sent}} ->
      {:error, {:after_chunk, conn, total_sent}, {:unexpected_status, status}}

    {:no_partial_on_resume, status, _acc} ->
      {:error, :status_no_partial, status}
  end

  # Finch.stream/5 callback — receives status / headers / data tuples
  # one at a time and threads our streaming accumulator through.
  defp handle_chunk({:status, status}, %{attempting_resume?: true} = acc)
       when status not in [206, 416] do
    # We requested a Range resume but the provider answered 200 (or some
    # other non-206 success). Bail out — restarting bytes from offset 0
    # would corrupt the player's decoder state.
    throw({:no_partial_on_resume, status, acc})
  end

  defp handle_chunk({:status, status}, acc) when status in 200..299 do
    %{acc | status: status}
  end

  defp handle_chunk({:status, status}, acc) do
    throw({:upstream_error, status, acc})
  end

  defp handle_chunk({:headers, headers}, acc) do
    conn = send_response_headers(acc.conn, acc.status || 200, headers, acc.attempting_resume?)
    %{acc | conn: conn, sent_headers?: true}
  end

  defp handle_chunk({:data, chunk}, acc) do
    case Conn.chunk(acc.conn, chunk) do
      {:ok, conn} ->
        size = byte_size(chunk)
        %{acc | conn: conn, total_sent: acc.total_sent + size, bytes_sent: acc.bytes_sent + size}

      {:error, :closed} ->
        # Player disconnected. Bail out so the upstream connection is
        # released back to the pool.
        throw({:client_closed, acc})
    end
  end

  defp handle_chunk({:trailers, _trailers}, acc), do: acc

  defp send_response_headers(conn, status, upstream_headers, attempting_resume?) do
    # When we resumed mid-stream the upstream only knows the remaining
    # byte range, so its `Content-Length` is the *tail* and its
    # `Content-Range` reflects the resumed window. The player has
    # already received the first portion via send_chunked, so we'd
    # rather not advertise a fresh length anyway.
    skip = if attempting_resume?, do: ["content-length", "content-range"], else: []

    conn
    |> copy_response_headers(upstream_headers, skip)
    |> Conn.put_resp_header("cache-control", "no-cache, no-store")
    |> put_cors_headers()
    |> Conn.send_chunked(status)
  end

  defp copy_response_headers(conn, upstream_headers, skip) do
    Enum.reduce(@forwardable_response_headers -- skip, conn, fn name, acc ->
      case List.keyfind(upstream_headers, name, 0) do
        {^name, value} -> Conn.put_resp_header(acc, name, value)
        _ -> acc
      end
    end)
  end

  defp put_cors_headers(conn) do
    conn
    |> Conn.put_resp_header("access-control-allow-origin", "*")
    |> Conn.put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> Conn.put_resp_header("access-control-allow-headers", "Range, Accept-Encoding")
    |> Conn.put_resp_header(
      "access-control-expose-headers",
      "Content-Length, Content-Range, Accept-Ranges"
    )
  end

  defp build_request_headers(conn, bytes_sent) do
    base = [
      {"user-agent", @upstream_user_agent},
      {"accept", "*/*"},
      # `Connection: close` — pooled idle connections trip
      # `max_connections=1` quotas and trigger 509 storms.
      {"connection", "close"}
    ]

    range_override = bytes_sent > 0

    forwardable =
      if range_override,
        do: @forwardable_request_headers -- ["range"],
        else: @forwardable_request_headers

    forwarded =
      Enum.reduce(forwardable, base, fn name, acc ->
        case Conn.get_req_header(conn, name) do
          [value | _] -> [{name, value} | acc]
          [] -> acc
        end
      end)

    if range_override do
      # Mid-stream resume — request the suffix the player still needs.
      [{"range", "bytes=#{bytes_sent}-"} | forwarded]
    else
      forwarded
    end
  end

  defp sanitize(url) do
    Regex.replace(~r{/(movie|series|live)/[^/]+/[^/]+/}, url, "/\\1/***/***/")
  end
end
