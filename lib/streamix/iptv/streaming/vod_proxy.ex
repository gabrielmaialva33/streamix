defmodule Streamix.Iptv.Streaming.VodProxy do
  @moduledoc """
  BEAM-side reverse proxy for IPTV VOD/Live streams.

  Pumps upstream bytes into a `Plug.Conn` via the dedicated
  `Streamix.StreamFinch` pool + `Plug.Conn.chunk/2`. Provider
  credentials stay server-side, long-lived player sockets are isolated
  from sync/API calls, and a mid-stream upstream failure is recovered
  with a Range-aware retry instead of erroring the player out.

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
        → Streamix.StreamFinch — pipes bytes into Plug.Conn.chunk/2
  """

  alias Plug.Conn
  alias Streamix.Iptv.Streaming.{FailoverPolicy, FallbackVideo, RedirectResolver, UpstreamPump}
  alias StreamixWeb.StreamErrors

  require Logger

  # XCIPTV is whitelisted by most IPTV providers' WAFs; the BEAM's default
  # `Req/...` UA gets bounced. Standardized across every Streamix surface
  # (catalog, EPG, multiplexer, redirect resolver) so the upstream sees a
  # single coherent client identity.
  @upstream_user_agent "XCIPTV-v6.0.0"

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

  # Burst buffer cap (bytes-in-flight) between Finch and Plug.Conn.chunk.
  # Decouples upstream pace from client pace so a microburst (GC pause,
  # transient congestion) doesn't stall the upstream socket.
  @burst_buffer_bytes 5 * 1024 * 1024

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
  @spec pipe(Conn.t(), String.t(), keyword()) :: Conn.t()
  def pipe(conn, url, opts \\ []) do
    url_chain = Keyword.get(opts, :url_chain, [url])
    pipe_chain(conn, url_chain)
  end

  # Tries each URL in the failover chain. The first one that boots up
  # and starts streaming wins; once we've sent bytes we stick with it
  # (mid-stream errors fall back to Range-aware retry against the same
  # host, never to a different one — splicing across hosts would break
  # the player's decoder state).
  defp pipe_chain(conn, []) do
    Logger.warning("[VodProxy] empty URL chain")
    StreamErrors.halt(conn, :stream_resolution_failed)
  end

  defp pipe_chain(conn, [url | rest]) do
    state = %{
      original_url: url,
      bytes_sent: 0,
      retry_count: 0,
      started_at: System.monotonic_time(:millisecond)
    }

    case resolve_chain(url) do
      {:ok, final_url} ->
        if FailoverPolicy.failover_url?(final_url) do
          Logger.warning(
            "[VodProxy] failover pattern hit on #{sanitize(final_url)}; rotating to next URL"
          )

          rotate_or_fallback(conn, rest, :failover_pattern_match)
        else
          conn = do_pipe(conn, final_url, state)
          maybe_rotate_after_pipe(conn, rest)
        end

      {:error, reason} ->
        Logger.warning("[VodProxy] resolve failed for #{sanitize(url)}: #{inspect(reason)}")
        rotate_or_fallback(conn, rest, reason)
    end
  end

  # We only rotate when nothing was sent yet. Once `send_chunked/2` ran,
  # the conn is committed to the player — switching hosts mid-stream
  # would corrupt the bytes already in flight.
  defp maybe_rotate_after_pipe(%Conn{state: state} = conn, _rest)
       when state in [:chunked, :sent, :file],
       do: conn

  defp maybe_rotate_after_pipe(conn, []), do: conn

  defp maybe_rotate_after_pipe(conn, rest) do
    Logger.info("[VodProxy] primary URL exhausted before headers; trying #{length(rest)} alt(s)")
    pipe_chain(conn, rest)
  end

  defp rotate_or_fallback(conn, [], reason), do: serve_fallback_or_halt(conn, reason)
  defp rotate_or_fallback(conn, rest, _reason), do: pipe_chain(conn, rest)

  defp serve_fallback_or_halt(conn, reason) do
    code = StreamErrors.code_from_reason(reason)
    category = FallbackVideo.category_from_reason(reason)

    case FallbackVideo.serve(conn, category) do
      %Conn{state: :file} = served -> served
      %Conn{state: :sent} = served -> served
      %Conn{state: :chunked} = served -> served
      _ -> StreamErrors.halt(conn, code)
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
    serve_fallback_or_halt(conn, {:unexpected_status, status})
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
      serve_fallback_or_halt(conn, reason)
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

  # Drains upstream into the conn through `UpstreamPump`. The pump runs in
  # its own Task so a slow client can't stall Finch packet-by-packet —
  # bytes-in-flight is bounded by `@burst_buffer_bytes` and the pump
  # waits for `{:ack, size}` from us once that window fills.
  defp stream_via_finch(conn, req, state) do
    acc = %{
      conn: conn,
      status: nil,
      sent_headers?: false,
      bytes_sent: state.bytes_sent,
      total_sent: state.bytes_sent,
      attempting_resume?: state.bytes_sent > 0
    }

    pump =
      UpstreamPump.start(req, Streamix.StreamFinch, self(),
        cap_bytes: @burst_buffer_bytes,
        receive_timeout: @upstream_idle_timeout_ms,
        pool_timeout: 5_000
      )

    try do
      consume_pump(pump, acc)
    after
      Task.shutdown(pump, :brutal_kill)
    end
  end

  defp consume_pump(pump, acc) do
    pump_pid = pump.pid
    pump_ref = pump.ref

    receive do
      {^pump_pid, {:status, status}} ->
        consume_pump(pump, on_status(status, acc))

      {^pump_pid, {:headers, headers}} ->
        consume_pump(pump, on_headers(headers, acc))

      {^pump_pid, {:data, chunk, size}} ->
        consume_pump(pump, on_data(chunk, size, acc, pump_pid))

      {^pump_pid, {:trailers, _trailers}} ->
        consume_pump(pump, acc)

      {^pump_pid, :done} ->
        on_pump_done(acc)

      {^pump_pid, {:error, reason}} ->
        on_pump_error(reason, acc)

      {:DOWN, ^pump_ref, :process, ^pump_pid, reason} ->
        # Task crashed (e.g. pump idle exit). Surface it as a transient
        # upstream error so the retry loop can attempt a fresh chain.
        on_pump_error({:pump_down, reason}, acc)
    end
  catch
    {:client_closed, _acc} ->
      {:error, :client_closed}

    {:upstream_error, status, %{sent_headers?: false}} ->
      if status in @terminal_statuses do
        {:error, :status_terminal, status}
      else
        {:error, :before_first_byte, {:unexpected_status, status}}
      end

    {:upstream_error, status, %{conn: conn, total_sent: total_sent}} ->
      {:error, {:after_chunk, conn, total_sent}, {:unexpected_status, status}}

    {:no_partial_on_resume, status, _acc} ->
      {:error, :status_no_partial, status}
  end

  defp on_status(status, %{attempting_resume?: true} = acc) when status not in [206, 416] do
    # We requested a Range resume but the provider answered 200 (or some
    # other non-206 success). Bail out — restarting bytes from offset 0
    # would corrupt the player's decoder state.
    throw({:no_partial_on_resume, status, acc})
  end

  defp on_status(status, acc) when status in 200..299, do: %{acc | status: status}
  defp on_status(status, acc), do: throw({:upstream_error, status, acc})

  defp on_headers(headers, acc) do
    conn = send_response_headers(acc.conn, acc.status || 200, headers, acc.attempting_resume?)
    %{acc | conn: conn, sent_headers?: true}
  end

  defp on_data(chunk, size, acc, pump_pid) do
    case Conn.chunk(acc.conn, chunk) do
      {:ok, conn} ->
        send(pump_pid, {:ack, size})
        %{acc | conn: conn, total_sent: acc.total_sent + size, bytes_sent: acc.bytes_sent + size}

      {:error, :closed} ->
        throw({:client_closed, acc})

      {:error, _reason} ->
        throw({:client_closed, acc})
    end
  end

  defp on_pump_done(%{sent_headers?: true} = acc), do: {:ok, acc.conn, acc}
  defp on_pump_done(_acc), do: {:error, :before_first_byte, :empty_upstream}

  defp on_pump_error(reason, %{sent_headers?: true, conn: conn, total_sent: total_sent}) do
    {:error, {:after_chunk, conn, total_sent}, reason}
  end

  defp on_pump_error(reason, _acc), do: {:error, :before_first_byte, reason}

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
