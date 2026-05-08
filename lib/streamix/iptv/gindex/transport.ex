defmodule Streamix.Iptv.Gindex.Transport do
  @moduledoc """
  Req transport, retry policy and endpoint health reporting for GIndex.
  """

  require Logger

  alias Streamix.Iptv.Gindex.EndpointManager
  alias Streamix.Iptv.Gindex.HealthTracker
  alias Streamix.Iptv.Gindex.Pacer

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(2)
  @max_retries 3

  # 503/429 means the upstream is rate-limiting us, so a long
  # exponential backoff gives the token bucket time to refill.
  @rate_limit_base_delay :timer.seconds(30)
  @max_rate_limit_retries 4

  # 500 from the goindex worker is the deterministic
  # "Cannot read properties of undefined (reading 'map')" bug
  # (see worker.js:2400 in @googledrive/index@2.3.6 — fixed in 2.5.6+).
  # Backing off for minutes does nothing because the bug fires on the
  # same (path, page_token) shape every time. Burn 2 fast retries —
  # which still gives us a fallback-endpoint shot at retry_server_error
  # — and then bubble the partial result up to the scraper.
  @server_error_base_delay :timer.seconds(5)
  @max_server_error_retries 2

  def request(method, url, body, base_url, opts \\ []) do
    request_with_retry(method, url, body, base_url, opts, 0, 0)
  end

  defp request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt) do
    case Pacer.acquire(:gdrive) do
      :ok -> :ok
      {:error, :timeout} -> Logger.warning("[GIndex Client] pacer timeout, proceeding anyway")
    end

    case Req.request(build_request_opts(method, url, body, opts)) do
      {:ok, response} ->
        handle_request_response(
          response,
          method,
          url,
          body,
          base_url,
          opts,
          attempt,
          rate_limit_attempt
        )

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        retry_transport_error(
          reason,
          method,
          url,
          body,
          base_url,
          opts,
          attempt,
          rate_limit_attempt
        )

      {:error, reason} ->
        EndpointManager.report_error(base_url)
        {:error, reason}
    end
  end

  defp build_request_opts(method, url, body, opts) do
    req_opts = [
      method: method,
      url: url,
      headers: build_headers(method),
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
      redirect: Keyword.get(opts, :follow_redirects, true),
      finch: Streamix.Finch
    ]

    if body, do: Keyword.put(req_opts, :body, body), else: req_opts
  end

  defp handle_request_response(
         response,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       ) do
    result =
      handle_response(response, method, url, body, base_url, opts, attempt, rate_limit_attempt)

    report_request_result(base_url, detect_operation(url, body), result)
    result
  end

  defp report_request_result(base_url, operation, {:ok, %{status: 200}}) do
    EndpointManager.report_success(base_url)
    HealthTracker.record_success(base_url, operation)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: status, body: resp_body}})
       when status >= 500 do
    error_type = detect_error_type(resp_body)
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, error_type)
  end

  defp report_request_result(base_url, operation, {:error, reason}) do
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, reason)
  end

  defp report_request_result(_base_url, _operation, _result), do: :ok

  defp retry_transport_error(
         reason,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       ) do
    Logger.warning("[GIndex] Request failed (attempt #{attempt + 1}): #{inspect(reason)}")

    if reason in [:nxdomain, :timeout] do
      :inet_db.clear_cache()
    end

    Process.sleep(@retry_delay)
    request_with_retry(method, url, body, base_url, opts, attempt + 1, rate_limit_attempt)
  end

  defp handle_response(
         %{status: status},
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       )
       when status in [429, 503] and rate_limit_attempt < @max_rate_limit_retries do
    delay = backoff_delay(rate_limit_attempt)

    Logger.warning(
      "[GIndex] Rate limited (#{status}), waiting #{div(delay, 1000)}s before retry " <>
        "(attempt #{rate_limit_attempt + 1}/#{@max_rate_limit_retries})"
    )

    Process.sleep(delay)
    request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt + 1)
  end

  defp handle_response(
         %{status: 500, body: resp_body} = response,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       )
       when rate_limit_attempt < @max_server_error_retries do
    body_str = if is_binary(resp_body), do: resp_body, else: inspect(resp_body)

    if auth_error?(body_str) do
      Logger.error("[GIndex] Authentication/Token error (500): #{String.slice(body_str, 0, 500)}")
      {:ok, response}
    else
      retry_server_error(method, url, body, base_url, opts, attempt, rate_limit_attempt, body_str)
    end
  end

  defp handle_response(
         response,
         _method,
         _url,
         _body,
         _base_url,
         _opts,
         _attempt,
         _rate_limit_attempt
       ) do
    {:ok, response}
  end

  defp retry_server_error(
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt,
         body_str
       ) do
    EndpointManager.report_error(base_url)

    case EndpointManager.get_endpoint() do
      {:ok, new_base_url} when new_base_url != base_url ->
        Logger.info("[GIndex] Switching to fallback endpoint: #{new_base_url}")
        path = String.replace_prefix(url, base_url, "")
        request_with_retry(method, new_base_url <> path, body, new_base_url, opts, attempt, 0)

      _ ->
        delay = server_error_delay(rate_limit_attempt)

        Logger.warning(
          "[GIndex] Server error (500) on #{method} #{url} body=#{String.slice(body_str, 0, 100)} " <>
            "req=#{summarize_retry_body(body)} " <>
            "waiting #{div(delay, 1000)}s before retry (attempt #{rate_limit_attempt + 1}/#{@max_server_error_retries})"
        )

        Process.sleep(delay)
        request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt + 1)
    end
  end

  defp server_error_delay(rate_limit_attempt) do
    base = (@server_error_base_delay * :math.pow(2, rate_limit_attempt)) |> round()
    base + :rand.uniform(1000)
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
