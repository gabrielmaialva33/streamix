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
      are transient and retried within a 30 s failure-burst budget,
      at most 5 attempts, 250 ms backoff.
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

  alias Streamix.SafeLog

  alias Streamix.Iptv.Streaming.{
    FailoverPolicy,
    FallbackVideo,
    ProviderRuntime,
    RedirectResolver,
    StreamErrors
  }

  alias Streamix.Iptv.Streaming.VodProxy.{Headers, Observability, Transfer}

  require Logger

  # Mid-stream retry budget. After this many attempts (or this many ms
  # in one uninterrupted failure sequence, whichever fires first) we
  # give up and let the player surface the error itself.
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
    context = Observability.context(opts)

    conn
    |> Conn.put_private(:streamix_proxy_context, context)
    |> with_provider_lease(context, &pipe_chain(&1, url_chain))
  end

  @spec head(Conn.t(), String.t(), keyword()) :: Conn.t()
  def head(conn, url, opts \\ []) do
    url_chain = Keyword.get(opts, :url_chain, [url])
    context = Observability.context(opts)

    conn = Conn.put_private(conn, :streamix_proxy_context, context)
    head_with_optional_lease(conn, url_chain, context)
  end

  defp head_with_optional_lease(conn, url_chain, %{dimension: :vod}),
    do: head_chain(url_chain, conn)

  defp head_with_optional_lease(conn, url_chain, context),
    do: with_provider_lease(conn, context, &head_chain(url_chain, &1))

  defp head_chain([], conn) do
    Observability.record_failure(
      Observability.context_from_conn(conn),
      :stream_resolution_failed
    )

    StreamErrors.halt(conn, :stream_resolution_failed)
  end

  defp head_chain([url | rest], conn) do
    case resolve_chain(url) do
      {:ok, final_url} ->
        case do_head(conn, final_url) do
          {:ok, conn} ->
            Observability.record_success(Observability.context_from_conn(conn))
            conn

          {:error, reason} ->
            rotate_head_or_halt(rest, conn, reason)
        end

      {:error, reason} ->
        rotate_head_or_halt(rest, conn, reason)
    end
  end

  defp rotate_head_or_halt([], conn, reason) do
    Observability.record_failure(Observability.context_from_conn(conn), reason)
    StreamErrors.halt(conn, StreamErrors.code_from_reason(reason))
  end

  defp rotate_head_or_halt(rest, conn, _reason), do: head_chain(rest, conn)

  defp do_head(conn, final_url) do
    headers = Headers.request(conn, 0)
    req = Finch.build(:head, final_url, headers)

    case Finch.request(req, Streamix.StreamFinch, receive_timeout: 10_000, pool_timeout: 5_000) do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        {:ok, Headers.send_head(conn, status, headers)}

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

    Observability.record_failure(
      Observability.context_from_conn(conn),
      :stream_resolution_failed
    )

    StreamErrors.halt(conn, :stream_resolution_failed)
  end

  defp pipe_chain(conn, [url | rest]) do
    state =
      Map.merge(Observability.context_from_conn(conn), %{
        original_url: url,
        bytes_sent: 0,
        retry_count: 0,
        retry_window_started_at: nil,
        started_at: System.monotonic_time(:millisecond)
      })

    Observability.emit(:start, state)

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
    Observability.record_failure(state, reason)
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
    Observability.record_failure(state, :retry_limit_exceeded)
    Observability.emit(:complete, state, outcome: :retry_limit_exceeded)

    conn
  end

  defp do_pipe(conn, final_url, state) do
    if exceeded_retry_budget?(state) do
      Logger.warning("[VodProxy] retry budget exhausted for #{sanitize(state.original_url)}")
      Observability.record_failure(state, :retry_budget_exhausted)
      Observability.emit(:complete, state, outcome: :retry_budget_exhausted)
      conn
    else
      do_pipe_attempt(conn, final_url, state)
    end
  end

  defp do_pipe_attempt(conn, final_url, state) do
    headers = Headers.request(conn, state.bytes_sent)
    req = Finch.build(:get, final_url, headers)

    handle_attempt_result(Transfer.stream(conn, req, state), conn, state)
  end

  defp handle_attempt_result({:ok, conn, final_state}, _conn, state) do
    Observability.record_success(state)
    Observability.emit(:complete, state, outcome: :ok, bytes_sent: final_state.total_sent)
    conn
  end

  defp handle_attempt_result({:error, :client_closed, chunked_conn, final_state}, _conn, state) do
    if final_state.total_sent > 0, do: Observability.record_success(state)
    Observability.emit(:client_closed, state, bytes_sent: final_state.total_sent)

    Observability.emit(:complete, state,
      outcome: :client_closed,
      bytes_sent: final_state.total_sent
    )

    chunked_conn
  end

  defp handle_attempt_result({:error, :before_first_byte, reason}, conn, state) do
    Observability.emit(:upstream_error, state, reason: reason)
    handle_pre_flight_error(conn, reason, state)
  end

  defp handle_attempt_result(
         {:error, {:after_chunk, chunked_conn, total_sent}, reason},
         _conn,
         state
       ) do
    Observability.emit(:upstream_error, state, reason: reason, bytes_sent: total_sent)
    handle_mid_stream_error(chunked_conn, total_sent, reason, state)
  end

  defp handle_attempt_result({:error, :status_terminal, status}, conn, state) do
    Logger.warning("[VodProxy] terminal upstream status #{status}")
    Observability.emit(:terminal_status, state, status: status)
    Observability.emit(:complete, state, outcome: :terminal_status, status: status)
    serve_fallback_or_halt(conn, {:unexpected_status, status}, state)
  end

  defp handle_attempt_result({:error, :status_no_partial, status}, conn, state) do
    Logger.warning("[VodProxy] reconnect aborted: upstream ignored Range and returned #{status}")
    Observability.record_failure(state, {:unexpected_status, status})
    Observability.emit(:complete, state, outcome: :status_no_partial, status: status)

    conn
  end

  defp handle_pre_flight_error(conn, reason, state) do
    if retryable_pre_flight_error?(reason) and state.retry_count < @max_mid_stream_retries do
      Logger.info(
        "[VodProxy] pre-flight failure (#{SafeLog.redact_inspect(reason)}); " <>
          "retry #{state.retry_count + 1}"
      )

      next_state = mark_retry(state, state.bytes_sent)
      Observability.emit(:upstream_retry, next_state, reason: reason)
      retry_with_fresh_chain(conn, next_state)
    else
      Logger.warning("[VodProxy] upstream pre-flight failed: #{SafeLog.redact_inspect(reason)}")

      Observability.emit(:complete, state, outcome: :pre_flight_failed, reason: reason)
      serve_fallback_or_halt(conn, reason, state)
    end
  end

  defp handle_mid_stream_error(chunked_conn, total_sent, reason, state) do
    if state.retry_count < @max_mid_stream_retries do
      Logger.warning(
        "[VodProxy] mid-stream upstream failure (#{SafeLog.redact_inspect(reason)}); " <>
          "resume @ byte #{total_sent}; retry #{state.retry_count + 1}"
      )

      state = mark_retry(state, total_sent)
      Observability.emit(:upstream_retry, state, reason: reason, bytes_sent: total_sent)
      retry_with_fresh_chain(chunked_conn, state)
    else
      Observability.record_failure(state, reason)

      Observability.emit(:complete, state,
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
        Observability.record_failure(state, reason)
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

  defp exceeded_retry_budget?(%{retry_window_started_at: nil}), do: false

  defp exceeded_retry_budget?(state) do
    monotonic_now() - state.retry_window_started_at > @retry_budget_ms
  end

  defp mark_retry(state, bytes_sent) do
    %{
      state
      | bytes_sent: bytes_sent,
        retry_count: state.retry_count + 1,
        retry_window_started_at: retry_window_started_at(state, bytes_sent)
    }
  end

  defp retry_window_started_at(%{retry_window_started_at: nil}, _bytes_sent),
    do: monotonic_now()

  defp retry_window_started_at(%{bytes_sent: previous_bytes}, bytes_sent)
       when bytes_sent > previous_bytes,
       do: monotonic_now()

  defp retry_window_started_at(state, _bytes_sent), do: state.retry_window_started_at

  defp monotonic_now, do: System.monotonic_time(:millisecond)

  defp sanitize(url) do
    SafeLog.redact_url(url)
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
        Observability.emit(:capacity_exhausted, state)
        StreamErrors.halt(conn, :provider_capacity_exhausted)
    end
  end
end
