defmodule Streamix.Gindex.Transport do
  @moduledoc """
  Req transport, retry policy and endpoint health reporting for GIndex.
  """

  require Logger

  alias Streamix.Gindex.EndpointManager
  alias Streamix.Gindex.HealthTracker
  alias Streamix.Gindex.Pacer
  alias Streamix.Gindex.QuotaGuard
  alias Streamix.Gindex.RequestBudget

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(2)
  @max_retries 3

  # Inline sleeps pin callers and used to block the global URL-cache process.
  # Propagate rate limits immediately; playback returns retry guidance and
  # background workers persist a durable pause before Oban reschedules them.
  @default_playback_retry_after 60
  @default_background_retry_after 15 * 60

  # Worker 500s, including the common JavaScript TypeError, are intermittent
  # across Cloudflare requests. Give the same origin two retries before
  # returning the error. Cross-Worker fallback happens only in Pagination,
  # which can safely restart a listing from page zero instead of replaying a
  # foreign cursor or signed token.
  @server_error_base_delay :timer.seconds(5)
  @max_server_error_retries 2

  @typep request_state :: %{
           method: atom(),
           url: String.t(),
           body: term(),
           base_url: String.t(),
           opts: keyword(),
           transport_attempt: non_neg_integer(),
           server_error_attempt: non_neg_integer(),
           max_transport_retries: non_neg_integer(),
           max_server_error_retries: non_neg_integer()
         }

  def request(method, url, body, base_url, opts \\ []) do
    workload = Keyword.get(opts, :workload, :background)

    request_with_retry(%{
      method: method,
      url: url,
      body: body,
      base_url: base_url,
      opts: opts,
      transport_attempt: 0,
      server_error_attempt: 0,
      max_transport_retries:
        Keyword.get(opts, :max_transport_retries, default_transport_retries(workload)),
      max_server_error_retries:
        Keyword.get(opts, :max_server_error_retries, default_server_error_retries(workload))
    })
  end

  @spec request_with_retry(request_state()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp request_with_retry(state) do
    %{base_url: base_url, opts: opts} = state
    operation = request_operation(state)

    case reserve_request(opts) do
      {:error, {:slice_exhausted, count}} ->
        emit_request_stop(:slice_exhausted, base_url, operation)
        {:error, {:slice_exhausted, count}}

      {:error, {:quota_exhausted, count}} ->
        :telemetry.execute(
          [:streamix, :gindex, :request, :stop],
          %{count: 1},
          %{
            outcome: :quota_exhausted,
            base_url: base_url,
            operation: operation
          }
        )

        {:error, {:quota_exhausted, count}}

      :ok ->
        request_after_quota(state)
    end
  end

  defp reserve_request(opts) do
    with :ok <- RequestBudget.consume() do
      case consume_quota(opts) do
        {:error, :exhausted, count} -> {:error, {:quota_exhausted, count}}
        _ -> :ok
      end
    end
  end

  @spec request_after_quota(request_state()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp request_after_quota(state) do
    %{
      base_url: base_url,
      body: body,
      max_transport_retries: max_transport_retries,
      method: method,
      opts: opts,
      transport_attempt: transport_attempt,
      url: url
    } = state

    operation = request_operation(state)

    case Pacer.acquire(:gdrive, pacing_timeout(state)) do
      :ok -> :ok
      {:error, :timeout} -> Logger.warning("[GIndex Client] pacer timeout, proceeding anyway")
    end

    case Req.request(build_request_opts(method, url, body, opts)) do
      {:ok, response} ->
        handle_request_response(response, state)

      {:error, %Req.TransportError{reason: reason} = error}
      when transport_attempt < max_transport_retries ->
        report_request_result(base_url, operation, {:error, error})

        retry_transport_error(reason, state)

      {:error, reason} ->
        report_request_result(base_url, operation, {:error, reason})
        {:error, reason}
    end
  end

  defp consume_quota(opts) do
    workload = Keyword.get(opts, :workload, :background)

    case Keyword.get(opts, :quota_fun) do
      fun when is_function(fun, 1) -> fun.(workload)
      fun when is_function(fun, 0) -> fun.()
      nil -> QuotaGuard.consume(workload)
    end
  end

  defp build_request_opts(method, url, body, opts) do
    req_opts =
      [
        method: method,
        url: url,
        headers: build_headers(method),
        receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
        redirect: Keyword.get(opts, :follow_redirects, true),
        retry: false,
        finch: [name: Streamix.Finch]
      ]
      |> maybe_put(:plug, Keyword.get(opts, :plug))

    if body, do: Keyword.put(req_opts, :body, body), else: req_opts
  end

  defp handle_request_response(response, state) do
    %{base_url: base_url} = state
    operation = request_operation(state)

    report_request_result(base_url, operation, {:ok, response})
    handle_response(response, state)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: 200}}) do
    EndpointManager.report_success(base_url)
    HealthTracker.record_success(base_url, operation)
    emit_request_stop(:ok, base_url, operation)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: 500, body: resp_body}})
       when is_binary(resp_body) do
    error_type = detect_error_type(resp_body)
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, error_type)
    outcome = if error_type == :javascript_error, do: :typeerror_skip, else: :other_error
    emit_request_stop(outcome, base_url, operation)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: status}})
       when status in [429, 503] do
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, :rate_limited)
    emit_request_stop(:rate_limited, base_url, operation)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: status, body: resp_body}})
       when status >= 500 do
    error_type = detect_error_type(resp_body)
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, error_type)
    emit_request_stop(:other_error, base_url, operation)
  end

  defp report_request_result(base_url, operation, {:error, reason}) do
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, reason)
    emit_request_stop(:other_error, base_url, operation)
  end

  defp report_request_result(_base_url, _operation, _result), do: :ok

  defp emit_request_stop(outcome, base_url, operation) do
    :telemetry.execute(
      [:streamix, :gindex, :request, :stop],
      %{count: 1},
      %{outcome: outcome, base_url: base_url, operation: operation}
    )
  end

  defp retry_transport_error(reason, state) do
    %{transport_attempt: transport_attempt} = state

    Logger.warning(
      "[GIndex] Request failed (attempt #{transport_attempt + 1}): #{inspect(reason)}"
    )

    if reason in [:nxdomain, :timeout] do
      :inet_db.clear_cache()
    end

    Process.sleep(@retry_delay)
    request_with_retry(%{state | transport_attempt: transport_attempt + 1})
  end

  defp handle_response(%{status: status} = response, state) when status in [429, 503] do
    retry_after = retry_after_seconds(response, request_workload(state))

    Logger.warning(
      "[GIndex] Rate limited (#{status}) operation=#{request_operation(state)} " <>
        "workload=#{request_workload(state)} retry_after=#{retry_after}s"
    )

    {:error, {:rate_limited, status, retry_after}}
  end

  defp handle_response(
         %{status: 500, body: resp_body} = response,
         %{
           server_error_attempt: server_error_attempt,
           max_server_error_retries: max_server_error_retries
         } = state
       )
       when server_error_attempt < max_server_error_retries do
    body_str = if is_binary(resp_body), do: resp_body, else: inspect(resp_body)

    if auth_error?(body_str) do
      Logger.error("[GIndex] Authentication/Token error (500): #{String.slice(body_str, 0, 500)}")

      {:ok, response}
    else
      retry_server_error(body_str, state)
    end
  end

  defp handle_response(response, _state) do
    {:ok, response}
  end

  defp retry_server_error(body_str, state) do
    %{
      body: body,
      method: method,
      opts: opts,
      server_error_attempt: server_error_attempt,
      url: url
    } = state

    delay = server_error_delay(server_error_attempt, opts)

    Logger.warning(
      "[GIndex] Server error (500) on #{method} #{url} body=#{String.slice(body_str, 0, 100)} " <>
        "req=#{summarize_retry_body(body)} " <>
        "waiting #{div(delay, 1000)}s before retry (attempt #{server_error_attempt + 1}/#{@max_server_error_retries})"
    )

    Process.sleep(delay)
    request_with_retry(%{state | server_error_attempt: server_error_attempt + 1})
  end

  defp server_error_delay(server_error_attempt, opts) do
    case Keyword.get(opts, :server_error_delay_ms) do
      delay when is_integer(delay) and delay >= 0 ->
        delay

      _ ->
        base = (@server_error_base_delay * :math.pow(2, server_error_attempt)) |> round()
        base + :rand.uniform(1000)
    end
  end

  defp summarize_retry_body(nil), do: "nil"

  defp summarize_retry_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"page_token" => page_token, "page_index" => page_index, "type" => type}} ->
        "type=#{type} page_token=#{page_token_marker(page_token)} page_index=#{page_index}"

      _ ->
        "raw=#{String.slice(body, 0, 100)}"
    end
  end

  defp summarize_retry_body(body), do: inspect(body)

  defp page_token_marker(page_token) when page_token in [nil, ""], do: "nil"
  defp page_token_marker(page_token), do: "TOKEN(#{byte_size(page_token)}B)"

  defp retry_after_seconds(response, workload) do
    case Req.Response.get_retry_after(response) do
      milliseconds when is_integer(milliseconds) and milliseconds >= 0 ->
        milliseconds
        |> ceil_div(1_000)
        |> max(1)
        |> min(3_600)

      _ ->
        fallback_retry_after(response, workload)
    end
  rescue
    _ -> fallback_retry_after(response, workload)
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp auth_error?(body) when is_binary(body) do
    body_lower = String.downcase(body)

    String.contains?(body_lower, "token") or
      String.contains?(body_lower, "auth") or
      String.contains?(body_lower, "expired") or
      String.contains?(body_lower, "invalid") or
      String.contains?(body_lower, "unauthorized") or
      String.contains?(body_lower, "forbidden") or
      String.contains?(body_lower, "access denied")
  end

  defp auth_error?(_), do: false

  defp build_headers(:post) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/plain, */*"},
      {"user-agent", "Mozilla/5.0 (compatible; Streamix/1.0)"}
    ]
  end

  defp build_headers(_method) do
    [
      {"accept", "*/*"},
      {"user-agent", "Mozilla/5.0 (compatible; Streamix/1.0)"}
    ]
  end

  defp detect_operation(url, body) do
    cond do
      String.contains?(url, "?a=") or String.contains?(url, "download") ->
        :stream

      is_binary(body) and String.contains?(body, "\"type\":\"file\"") ->
        :file_info

      true ->
        :list
    end
  end

  defp request_operation(%{opts: opts, url: url, body: body}) do
    Keyword.get_lazy(opts, :operation, fn -> detect_operation(url, body) end)
  end

  defp request_workload(%{opts: opts}), do: Keyword.get(opts, :workload, :background)

  defp default_transport_retries(:playback), do: 0
  defp default_transport_retries(_workload), do: @max_retries

  defp default_server_error_retries(:playback), do: 0
  defp default_server_error_retries(_workload), do: @max_server_error_retries

  defp pacing_timeout(%{opts: opts}) do
    case Keyword.get(opts, :workload, :background) do
      :playback -> :timer.seconds(2)
      _workload -> :timer.seconds(60)
    end
  end

  defp default_retry_after(:playback), do: @default_playback_retry_after
  defp default_retry_after(_workload), do: @default_background_retry_after

  # Cloudflare Error 1027 is the Workers Free daily request ceiling. It resets
  # at midnight UTC, so short canary retries only burn more requests and keep
  # the sync workflow awake without any chance of recovery.
  defp fallback_retry_after(%{status: 429, body: body}, workload) when is_binary(body) do
    if String.contains?(String.downcase(body), "error code: 1027") do
      QuotaGuard.seconds_until_reset()
    else
      default_retry_after(workload)
    end
  end

  defp fallback_retry_after(_response, workload), do: default_retry_after(workload)

  defp detect_error_type(body) when is_binary(body) do
    cond do
      String.contains?(body, "TypeError") -> :javascript_error
      String.contains?(body, "Cannot read properties") -> :javascript_error
      String.contains?(body, "rate limit") -> :rate_limit
      String.contains?(body, "quota") -> :quota_exceeded
      true -> :unknown_server_error
    end
  end

  defp detect_error_type(_), do: :unknown
end
