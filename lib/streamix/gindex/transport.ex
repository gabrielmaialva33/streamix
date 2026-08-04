defmodule Streamix.Gindex.Transport do
  @moduledoc """
  Req transport, retry policy and endpoint health reporting for GIndex.
  """

  require Logger

  alias Streamix.Gindex.EndpointManager
  alias Streamix.Gindex.HealthTracker
  alias Streamix.Gindex.Pacer
  alias Streamix.Gindex.QuotaGuard

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(2)
  @max_retries 3

  # 503/429 means the upstream is rate-limiting us, so a long
  # exponential backoff gives the token bucket time to refill.
  @rate_limit_base_delay :timer.seconds(30)
  @max_rate_limit_retries 4

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
           rate_limit_attempt: non_neg_integer(),
           server_error_attempt: non_neg_integer()
         }

  def request(method, url, body, base_url, opts \\ []) do
    request_with_retry(%{
      method: method,
      url: url,
      body: body,
      base_url: base_url,
      opts: opts,
      transport_attempt: 0,
      rate_limit_attempt: 0,
      server_error_attempt: 0
    })
  end

  @spec request_with_retry(request_state()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp request_with_retry(state) do
    %{base_url: base_url, body: body, opts: opts, url: url} = state

    case consume_quota(opts) do
      {:error, :exhausted, count} ->
        :telemetry.execute(
          [:streamix, :gindex, :request, :stop],
          %{count: 1},
          %{
            outcome: :quota_exhausted,
            base_url: base_url,
            operation: detect_operation(url, body)
          }
        )

        {:error, {:quota_exhausted, count}}

      _ ->
        request_after_quota(state)
    end
  end

  @spec request_after_quota(request_state()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp request_after_quota(state) do
    %{
      base_url: base_url,
      body: body,
      method: method,
      opts: opts,
      transport_attempt: transport_attempt,
      url: url
    } = state

    case Pacer.acquire(:gdrive) do
      :ok -> :ok
      {:error, :timeout} -> Logger.warning("[GIndex Client] pacer timeout, proceeding anyway")
    end

    case Req.request(build_request_opts(method, url, body, opts)) do
      {:ok, response} ->
        handle_request_response(response, state)

      {:error, %Req.TransportError{reason: reason} = error}
      when transport_attempt < @max_retries ->
        report_request_result(base_url, detect_operation(url, body), {:error, error})

        retry_transport_error(reason, state)

      {:error, reason} ->
        report_request_result(base_url, detect_operation(url, body), {:error, reason})
        {:error, reason}
    end
  end

  defp consume_quota(opts) do
    opts
    |> Keyword.get(:quota_fun, &QuotaGuard.consume/0)
    |> then(& &1.())
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
    %{base_url: base_url, body: body, url: url} = state

    report_request_result(base_url, detect_operation(url, body), {:ok, response})
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

  defp handle_response(
         %{status: status},
         %{rate_limit_attempt: rate_limit_attempt} = state
       )
       when status in [429, 503] and rate_limit_attempt < @max_rate_limit_retries do
    %{opts: opts} = state
    delay = rate_limit_delay(rate_limit_attempt, opts)

    Logger.warning(
      "[GIndex] Rate limited (#{status}), waiting #{div(delay, 1000)}s before retry " <>
        "(attempt #{rate_limit_attempt + 1}/#{@max_rate_limit_retries})"
    )

    Process.sleep(delay)
    request_with_retry(%{state | rate_limit_attempt: rate_limit_attempt + 1})
  end

  defp handle_response(
         %{status: 500, body: resp_body} = response,
         %{server_error_attempt: server_error_attempt} = state
       )
       when server_error_attempt < @max_server_error_retries do
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

  defp rate_limit_delay(rate_limit_attempt, opts) do
    case Keyword.get(opts, :rate_limit_delay_ms) do
      delay when is_integer(delay) and delay >= 0 ->
        delay

      _ ->
        backoff_delay(rate_limit_attempt)
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

  defp backoff_delay(rate_limit_attempt) do
    base_delay = (@rate_limit_base_delay * :math.pow(2, rate_limit_attempt)) |> round()
    base_delay + :rand.uniform(2000)
  end

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
