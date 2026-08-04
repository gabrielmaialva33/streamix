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

  alias Streamix.Iptv.Channels
  alias Streamix.SafeLog

  alias Streamix.Iptv.Streaming.{
    FailoverPolicy,
    FallbackVideo,
    ProviderRuntime,
    RedirectResolver,
    StreamErrors,
    UpstreamPolicy,
    UpstreamPump
  }

  require Logger

  # IPTVSmartersPlayer is whitelisted by most IPTV providers' WAFs; the BEAM's default
  # `Req/...` UA gets bounced. Standardized across every Streamix surface
  # (catalog, EPG, multiplexer, redirect resolver) so the upstream sees a
  # single coherent client identity.
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
  #
  # 30 s matches the longest stall we have seen on the X99 edge
  # (`209.14.85.202`) before its WAF/throttle releases the socket.
  # The original 5 s budget made us give up well before the upstream
  # would have recovered, which surfaced as "cai no meio do filme"
  # client-side even when a one-second wait was all the upstream
  # needed.
  @max_mid_stream_retries 5
  @retry_budget_ms 30_000
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
    context = stream_context(opts)

    conn
    |> Conn.put_private(:streamix_proxy_context, context)
    |> with_provider_lease(context, &pipe_chain(&1, url_chain))
  end

  @spec head(Conn.t(), String.t(), keyword()) :: Conn.t()
  def head(conn, url, opts \\ []) do
    url_chain = Keyword.get(opts, :url_chain, [url])
    context = stream_context(opts)

    conn
    |> Conn.put_private(:streamix_proxy_context, context)
    |> with_provider_lease(context, &head_chain(url_chain, &1))
  end

  defp head_chain([], conn) do
    record_failure(proxy_context(conn), :stream_resolution_failed)
    StreamErrors.halt(conn, :stream_resolution_failed)
  end

  defp head_chain([url | rest], conn) do
    case resolve_chain(url) do
      {:ok, final_url} ->
        case do_head(conn, final_url) do
          {:ok, conn} ->
            record_success(proxy_context(conn))
            conn

          {:error, reason} ->
            rotate_head_or_halt(rest, conn, reason)
        end

      {:error, reason} ->
        rotate_head_or_halt(rest, conn, reason)
    end
  end

  defp rotate_head_or_halt([], conn, reason) do
    record_failure(proxy_context(conn), reason)
    StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
  end

  defp rotate_head_or_halt(rest, conn, _reason), do: head_chain(rest, conn)

  defp do_head(conn, final_url) do
    headers = build_request_headers(conn, 0)
    req = Finch.build(:head, final_url, headers)

    case Finch.request(req, Streamix.StreamFinch, receive_timeout: 10_000, pool_timeout: 5_000) do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        conn =
          conn
          |> copy_response_headers(headers, [])
          |> ensure_accept_ranges()
          |> Conn.put_resp_header("cache-control", "no-cache, no-store")
          |> put_cors_headers()
          |> Conn.send_resp(status, "")

        {:ok, conn}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Tries each URL in the failover chain. The first one that boots up
  # and starts streaming wins; once we've sent bytes we stick with it
  # (mid-stream errors fall back to Range-aware retry against the same
  # host, never to a different one — splicing across hosts would break
  # the player's decoder state).
  defp pipe_chain(conn, []) do
    Logger.warning("[VodProxy] empty URL chain")
    record_failure(proxy_context(conn), :stream_resolution_failed)
    StreamErrors.halt(conn, :stream_resolution_failed)
  end

  defp pipe_chain(conn, [url | rest]) do
    state =
      Map.merge(proxy_context(conn), %{
        original_url: url,
        bytes_sent: 0,
        retry_count: 0,
        started_at: System.monotonic_time(:millisecond)
      })

    emit_telemetry(:start, state)

    case resolve_chain(url) do
      {:ok, final_url} ->
        if FailoverPolicy.failover_url?(final_url) do
          Logger.warning(
            "[VodProxy] failover pattern hit on #{sanitize(final_url)}; rotating to next URL"
          )

          rotate_or_fallback(conn, rest, :failover_pattern_match, state)
        else
          conn = do_pipe(conn, final_url, state)
          maybe_rotate_after_pipe(conn, rest)
        end

      {:error, reason} ->
        Logger.warning(
          "[VodProxy] resolve failed for #{sanitize(url)}: #{SafeLog.redact_inspect(reason)}"
        )

        rotate_or_fallback(conn, rest, reason, state)
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

  defp rotate_or_fallback(conn, [], reason, state),
    do: serve_fallback_or_halt(conn, reason, state)

  defp rotate_or_fallback(conn, rest, _reason, _state), do: pipe_chain(conn, rest)

  defp serve_fallback_or_halt(conn, reason, state) do
    record_failure(state, reason)
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
    record_failure(state, :retry_limit_exceeded)
    emit_telemetry(:complete, state, outcome: :retry_limit_exceeded)

    conn
  end

  defp do_pipe(conn, final_url, state) do
    if exceeded_retry_budget?(state) do
      Logger.warning("[VodProxy] retry budget exhausted for #{sanitize(state.original_url)}")
      record_failure(state, :retry_budget_exhausted)
      emit_telemetry(:complete, state, outcome: :retry_budget_exhausted)
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

  defp handle_attempt_result({:ok, conn, final_state}, _conn, state) do
    record_success(state)
    emit_telemetry(:complete, state, outcome: :ok, bytes_sent: final_state.total_sent)
    conn
  end

  defp handle_attempt_result({:error, :client_closed, chunked_conn, final_state}, _conn, state) do
    if final_state.total_sent > 0, do: record_success(state)
    emit_telemetry(:client_closed, state, bytes_sent: final_state.total_sent)
    emit_telemetry(:complete, state, outcome: :client_closed, bytes_sent: final_state.total_sent)
    chunked_conn
  end

  defp handle_attempt_result({:error, :before_first_byte, reason}, conn, state) do
    emit_telemetry(:upstream_error, state, reason: reason)
    handle_pre_flight_error(conn, reason, state)
  end

  defp handle_attempt_result(
         {:error, {:after_chunk, chunked_conn, total_sent}, reason},
         _conn,
         state
       ) do
    emit_telemetry(:upstream_error, state, reason: reason, bytes_sent: total_sent)
    handle_mid_stream_error(chunked_conn, total_sent, reason, state)
  end

  defp handle_attempt_result({:error, :status_terminal, status}, conn, state) do
    Logger.warning("[VodProxy] terminal upstream status #{status}")
    emit_telemetry(:terminal_status, state, status: status)
    emit_telemetry(:complete, state, outcome: :terminal_status, status: status)
    serve_fallback_or_halt(conn, {:unexpected_status, status}, state)
  end

  defp handle_attempt_result({:error, :status_no_partial, status}, conn, state) do
    Logger.warning("[VodProxy] reconnect aborted: upstream ignored Range and returned #{status}")
    record_failure(state, {:unexpected_status, status})
    emit_telemetry(:complete, state, outcome: :status_no_partial, status: status)

    conn
  end

  defp handle_pre_flight_error(conn, reason, state) do
    if retryable_pre_flight_error?(reason) and state.retry_count < @max_mid_stream_retries do
      Logger.info(
        "[VodProxy] pre-flight failure (#{SafeLog.redact_inspect(reason)}); " <>
          "retry #{state.retry_count + 1}"
      )

      next_state = %{state | retry_count: state.retry_count + 1}
      emit_telemetry(:upstream_retry, next_state, reason: reason)
      retry_with_fresh_chain(conn, next_state)
    else
      Logger.warning("[VodProxy] upstream pre-flight failed: #{SafeLog.redact_inspect(reason)}")

      emit_telemetry(:complete, state, outcome: :pre_flight_failed, reason: reason)
      serve_fallback_or_halt(conn, reason, state)
    end
  end

  defp handle_mid_stream_error(chunked_conn, total_sent, reason, state) do
    if state.retry_count < @max_mid_stream_retries do
      Logger.warning(
        "[VodProxy] mid-stream upstream failure (#{SafeLog.redact_inspect(reason)}); " <>
          "resume @ byte #{total_sent}; retry #{state.retry_count + 1}"
      )

      state = %{state | bytes_sent: total_sent, retry_count: state.retry_count + 1}
      emit_telemetry(:upstream_retry, state, reason: reason, bytes_sent: total_sent)
      retry_with_fresh_chain(chunked_conn, state)
    else
      record_failure(state, reason)

      emit_telemetry(:complete, state,
        outcome: :mid_stream_retry_limit_exceeded,
        bytes_sent: total_sent
      )

      chunked_conn
    end
  end

  defp retry_with_fresh_chain(conn, state) do
    # Backoff with full jitter so N concurrent viewers retrying the same
    # 5xx upstream don't all wake up in lockstep and re-hammer it.
    Process.sleep(@retry_backoff_ms + :rand.uniform(@retry_backoff_ms))

    case resolve_chain(state.original_url) do
      {:ok, fresh_url} ->
        do_pipe(conn, fresh_url, state)

      {:error, reason} ->
        record_failure(state, reason)
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
    {:client_closed, %{conn: conn} = acc} ->
      {:error, :client_closed, conn, acc}

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

  defp on_headers(_headers, %{attempting_resume?: true, conn: %Conn{state: :chunked}} = acc) do
    # The downstream response is already committed. The resumed upstream
    # headers describe only the remaining range and can't be sent again.
    %{acc | sent_headers?: true}
  end

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
    |> ensure_accept_ranges()
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

  defp ensure_accept_ranges(conn) do
    if Conn.get_resp_header(conn, "accept-ranges") == [] do
      Conn.put_resp_header(conn, "accept-ranges", "bytes")
    else
      conn
    end
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
      {"user-agent", UpstreamPolicy.user_agent()},
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
    SafeLog.redact_url(url)
  end

  defp stream_context(opts) do
    media_type = opts |> Keyword.get(:media_type) |> normalize_media_type()

    %{
      provider_id: Keyword.get(opts, :provider_id),
      content_id: Keyword.get(opts, :content_id),
      media_type: media_type,
      dimension: if(media_type == "channel", do: :live, else: :vod),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp proxy_context(conn) do
    Map.get(conn.private, :streamix_proxy_context) || stream_context([])
  end

  defp with_provider_lease(conn, context, fun) do
    case ProviderRuntime.acquire(context.provider_id, context.dimension) do
      {:ok, lease} ->
        try do
          fun.(conn)
        after
          ProviderRuntime.release(lease)
        end

      {:error, :capacity_exhausted} ->
        state = Map.merge(context, %{bytes_sent: 0, retry_count: 0})
        emit_telemetry(:capacity_exhausted, state)
        StreamErrors.halt(conn, :provider_capacity_exhausted)
    end
  end

  defp record_success(%{provider_id: provider_id, dimension: dimension} = state)
       when is_integer(provider_id) do
    latency_ms = System.monotonic_time(:millisecond) - state.started_at
    ProviderRuntime.record_success(provider_id, dimension, latency_ms)
    maybe_mark_channel_alive(state)
  end

  defp record_success(_state), do: :ok

  defp record_failure(%{provider_id: provider_id, dimension: dimension} = state, reason)
       when is_integer(provider_id) do
    if content_missing?(reason) do
      maybe_mark_channel_dead(state)
    else
      ProviderRuntime.record_failure(provider_id, dimension, reason)
    end
  end

  defp record_failure(_state, _reason), do: :ok

  defp content_missing?({:unexpected_status, status}) when status in [404, 410], do: true
  defp content_missing?(_), do: false

  defp maybe_mark_channel_alive(%{media_type: "channel", content_id: content_id})
       when is_integer(content_id),
       do: safe_channel_update(fn -> Channels.mark_alive(content_id) end)

  defp maybe_mark_channel_alive(_state), do: :ok

  defp maybe_mark_channel_dead(%{media_type: "channel", content_id: content_id})
       when is_integer(content_id),
       do: safe_channel_update(fn -> Channels.mark_dead(content_id) end)

  defp maybe_mark_channel_dead(_state), do: :ok

  defp safe_channel_update(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[VodProxy] channel liveness update failed: #{Exception.message(error)}")
      :ok
  end

  defp normalize_media_type(nil), do: nil
  defp normalize_media_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_media_type(value) when is_binary(value), do: value
  defp normalize_media_type(_), do: nil

  defp emit_telemetry(event, state, metadata \\ []) do
    metadata =
      metadata
      |> Keyword.put(:retry_count, state.retry_count)
      |> Keyword.put(:duration_ms, System.monotonic_time(:millisecond) - state.started_at)
      |> maybe_put_metadata(:provider_id, Map.get(state, :provider_id))
      |> maybe_put_metadata(:content_id, Map.get(state, :content_id))
      |> maybe_put_metadata(:media_type, Map.get(state, :media_type))

    measurements = %{
      bytes_sent: Keyword.get(metadata, :bytes_sent, state.bytes_sent),
      retry_count: state.retry_count,
      duration_ms: Keyword.fetch!(metadata, :duration_ms)
    }

    metadata =
      metadata
      |> Keyword.delete(:bytes_sent)
      |> Keyword.delete(:duration_ms)
      |> Map.new()

    :telemetry.execute([:streamix, :stream_proxy, event], measurements, metadata)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)
end
