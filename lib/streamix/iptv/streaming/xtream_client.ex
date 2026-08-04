defmodule Streamix.Iptv.XtreamClient do
  @moduledoc """
  HTTP client for Xtream Codes JSON API with Circuit Breaker protection.

  Endpoints:
  - Account info (no action)
  - Live: get_live_categories, get_live_streams
  - VOD: get_vod_categories, get_vod_streams, get_vod_info
  - Series: get_series_categories, get_series, get_series_info

  Circuit Breaker (Netflix pattern):
  - Tracks errors per provider
  - Opens circuit after 5 errors in 1 minute
  - Auto-recovers after 3 minutes cooldown
  - Fail-fast when circuit is open
  """

  alias Streamix.Iptv.Streaming.{ProviderRuntime, UpstreamPolicy}
  alias Streamix.Iptv.Sync.Telemetry
  alias Streamix.Iptv.XtreamCircuitBreaker
  alias Streamix.SafeLog
  alias Streamix.Security.UrlValidator

  require Logger

  @timeout :timer.seconds(30)
  @max_retries 3
  @base_retry_delay 10_000
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  # ============================================================================
  # Account
  # ============================================================================

  def get_account_info(url, username, password, opts \\ []) do
    api_call(url, username, password, nil, %{}, opts)
  end

  # ============================================================================
  # Live TV
  # ============================================================================

  def get_live_categories(url, username, password, opts \\ []) do
    api_call(url, username, password, "get_live_categories", %{}, opts)
  end

  def get_live_streams(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_live_streams", params, opts)
  end

  # ============================================================================
  # VOD (Movies)
  # ============================================================================

  def get_vod_categories(url, username, password, opts \\ []) do
    api_call(url, username, password, "get_vod_categories", %{}, opts)
  end

  def get_vod_streams(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_vod_streams", params, opts)
  end

  def get_vod_info(url, username, password, vod_id, opts \\ []) do
    api_call(url, username, password, "get_vod_info", %{vod_id: vod_id}, opts)
  end

  # ============================================================================
  # Series
  # ============================================================================

  def get_series_categories(url, username, password, opts \\ []) do
    api_call(url, username, password, "get_series_categories", %{}, opts)
  end

  def get_series(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_series", params, opts)
  end

  def get_series_info(url, username, password, series_id, opts \\ []) do
    api_call(url, username, password, "get_series_info", %{series_id: series_id}, opts)
  end

  # ============================================================================
  # EPG
  # ============================================================================

  @doc """
  Fetches short EPG data for a specific stream.

  ## Deprecated for bulk sync

  Iterating channel-by-channel triggers anti-scraper WAFs. For
  full-catalog EPG sync use `get_xmltv/3` — a single request that
  returns all channels at once, which mirrors what XCIPTV, TiviMate,
  IPTVSmarters and IBOPlayer do.
  """
  def get_short_epg(url, username, password, stream_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    api_call(
      url,
      username,
      password,
      "get_short_epg",
      %{stream_id: stream_id, limit: limit},
      opts
    )
  end

  @doc """
  Fetches simple EPG data table for a stream.
  """
  def get_simple_data_table(url, username, password, stream_id, opts \\ []) do
    api_call(
      url,
      username,
      password,
      "get_simple_data_table",
      %{stream_id: stream_id},
      opts
    )
  end

  @doc """
  Fetches the **full** EPG as an XMLTV document via `/xmltv.php`. One
  request returns the EPG for every channel in the catalog (typical
  size 5-20 MB). Mirrors what real IPTV client apps do.

  Returns `{:ok, raw_xml_body}` on success. Bypasses the JSON
  `api_call/5` path because the response is XML.
  """
  def get_xmltv(url, username, password, opts \\ []) do
    base = String.trim_trailing(url, "/")

    target =
      "#{base}/xmltv.php?username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}"

    provider_id = circuit_key(url, username, opts)

    tracked_control_call(provider_id, fn ->
      with_circuit_breaker(provider_id, "get_xmltv", fn ->
        request_document(target, opts, :timer.seconds(120), :empty_xmltv)
      end)
    end)
  end

  @doc """
  Fetches the **full** catalog as an M3U Plus playlist via `/get.php`.

  This is the same endpoint real Xtream client apps (XCIPTV, TiviMate,
  IPTV Smarters) hit on first launch. One request returns every live
  channel + every movie + every episode of every series, all flattened
  into `#EXTINF` rows. Typical size 5-50 MB.

  Why this matters: the legacy `get_live_streams` / `get_vod_streams` /
  `get_series` / `get_series_info × N` ladder hammers the upstream with
  thousands of requests, which is what caused production to be IP-banned
  by `cb.chokitecnologia.com` after a single sync. One M3U pull at boot
  keeps us under the provider's `max_connections` budget.

  Returns `{:ok, raw_m3u_body}` on success. Body parsing is the parser's
  job — we hand back raw bytes so the caller can stream it.
  """
  def get_m3u_plus(url, username, password, opts \\ []) do
    base = String.trim_trailing(url, "/")

    target =
      "#{base}/get.php?username=#{URI.encode_www_form(username)}" <>
        "&password=#{URI.encode_www_form(password)}&type=m3u_plus&output=ts"

    provider_id = circuit_key(url, username, opts)

    tracked_control_call(provider_id, fn ->
      with_circuit_breaker(provider_id, "get_m3u_plus", fn ->
        request_document(target, opts, :timer.seconds(180), :empty_m3u)
      end)
    end)
  end

  # ============================================================================
  # Stream URLs
  # ============================================================================

  def live_stream_url(base_url, username, password, stream_id) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/live/#{username}/#{password}/#{stream_id}.ts"
  end

  def movie_stream_url(base_url, username, password, stream_id, extension) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/movie/#{username}/#{password}/#{stream_id}.#{extension}"
  end

  def episode_stream_url(base_url, username, password, episode_id, extension) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/series/#{username}/#{password}/#{episode_id}.#{extension}"
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp api_call(base_url, username, password, action, extra_params, opts) do
    url = build_url(base_url, username, password, action, extra_params)
    action_name = action || "account_info"

    provider_id = circuit_key(base_url, username, opts)

    tracked_control_call(provider_id, fn ->
      with_circuit_breaker(provider_id, action_name, fn -> do_api_call(url, 0, opts) end)
    end)
  end

  defp request_document(target, opts, default_timeout, empty_error) do
    request_opts = [
      receive_timeout: Keyword.get(opts, :request_timeout, default_timeout),
      finch: [name: Streamix.Finch],
      headers: [{"user-agent", UpstreamPolicy.user_agent()}],
      decode_body: false,
      redirect: false,
      retry: false
    ]

    case safe_get(target, request_opts, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, empty_error}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_api_call(url, attempt, opts) do
    request_timeout = Keyword.get(opts, :request_timeout, @timeout)
    max_retries = Keyword.get(opts, :max_retries, @max_retries)

    request_opts = [
      receive_timeout: request_timeout,
      finch: [name: Streamix.Finch],
      headers: [{"user-agent", UpstreamPolicy.user_agent()}],
      redirect: false,
      retry: false
    ]

    # Use dedicated Finch pool for connection reuse during sync.
    # Redirects are followed manually so every hop is checked against
    # the SSRF policy before the socket is opened.
    case safe_get(url, request_opts, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 429}} when attempt < max_retries ->
        # Rate limited — full-jitter exponential backoff. Picking a delay
        # uniformly in [base, 2 * base * 2^attempt) spreads parallel
        # retries across a wide window so N workers receiving a 429 at
        # the same tick don't all wake up together and re-hammer the
        # upstream (which the AWS Architecture Blog calls the
        # "thundering herd" failure mode).
        delay = full_jitter_delay(attempt)

        Logger.warning(
          "[XtreamClient] Rate limited (429), retry #{attempt + 1}/#{max_retries} in #{div(delay, 1000)}s"
        )

        Process.sleep(delay)
        do_api_call(url, attempt + 1, opts)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} when attempt < max_retries ->
        # Same full-jitter backoff as the 429 branch — see comment above.
        delay = full_jitter_delay(attempt)

        Logger.warning(
          "[XtreamClient] Transport error #{SafeLog.redact_inspect(reason)}, " <>
            "retry #{attempt + 1}/#{max_retries}"
        )

        Process.sleep(delay)
        do_api_call(url, attempt + 1, opts)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Full-jitter exponential backoff (AWS-style). Picks a delay uniformly in
  # [base, 2 * base * 2^attempt). At attempt 0 that's [10s, 30s); at
  # attempt 2, [10s, 90s). Wider spread than a `base + small_jitter` recipe
  # so concurrent retries don't all wake up in the same 1–2s window.
  defp full_jitter_delay(attempt) do
    upper = @base_retry_delay * round(:math.pow(2, attempt + 1))
    @base_retry_delay + :rand.uniform(upper - @base_retry_delay)
  end

  # Categorize errors for circuit breaker metrics
  defp categorize_error({:http_error, status}) when status >= 500, do: :server_error
  defp categorize_error({:http_error, 429}), do: :rate_limited
  defp categorize_error({:http_error, status}) when status >= 400, do: :client_error
  defp categorize_error({:transport_error, :timeout}), do: :timeout
  defp categorize_error({:transport_error, _}), do: :transport_error
  defp categorize_error(_), do: :unknown

  defp with_circuit_breaker(provider_id, action_name, fun) do
    case XtreamCircuitBreaker.allow_request?(provider_id) do
      :ok ->
        Telemetry.span_api_call(provider_id, action_name, fn ->
          result = fun.()
          report_api_result(provider_id, result)
          result
        end)

      {:error, {:circuit_open, remaining_seconds}} ->
        Logger.warning(
          "[XtreamClient] Circuit OPEN for provider #{provider_id}, failing fast " <>
            "(retry in #{remaining_seconds}s)"
        )

        {:error, {:circuit_open, remaining_seconds}}

      {:error, :circuit_half_open_limit} ->
        Logger.debug("[XtreamClient] Circuit HALF-OPEN limit reached, waiting for test results")
        {:error, :circuit_half_open_limit}
    end
  end

  defp report_api_result(provider_id, {:ok, _}) do
    XtreamCircuitBreaker.report_success(provider_id)
  end

  defp report_api_result(provider_id, {:error, error_type}) do
    XtreamCircuitBreaker.report_error(provider_id, categorize_error(error_type))
  end

  defp tracked_control_call(provider_id, fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    latency_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, _} -> ProviderRuntime.record_success(provider_id, :control, latency_ms)
      {:error, reason} -> ProviderRuntime.record_failure(provider_id, :control, reason)
    end

    result
  end

  defp build_url(base_url, username, password, action, extra_params) do
    base = String.trim_trailing(base_url, "/")
    user = URI.encode_www_form(username)
    pass = URI.encode_www_form(password)

    params =
      %{username: user, password: pass}
      |> maybe_add_action(action)
      |> Map.merge(extra_params)
      |> URI.encode_query()

    "#{base}/player_api.php?#{params}"
  end

  defp maybe_add_action(params, nil), do: params
  defp maybe_add_action(params, action), do: Map.put(params, :action, action)

  defp safe_get(url, request_opts, opts, redirects \\ 0) do
    validator_opts =
      if Keyword.get(opts, :allow_private_network, false) do
        [allow_private_network: true]
      else
        []
      end

    with :ok <- UrlValidator.validate_url(url, validator_opts),
         {:ok, response} <- Req.get(url, request_opts) do
      follow_safe_redirect(url, response, request_opts, opts, redirects)
    end
  end

  defp follow_safe_redirect(url, %{status: status} = response, request_opts, opts, redirects)
       when status in @redirect_statuses do
    max_redirects = Keyword.get(opts, :max_redirects, @max_redirects)

    with true <- redirects < max_redirects,
         [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, next_url} <- resolve_redirect(url, location) do
      safe_get(next_url, request_opts, opts, redirects + 1)
    else
      false -> {:error, :too_many_redirects}
      [] -> {:error, :missing_redirect_location}
      {:error, _reason} = error -> error
    end
  end

  defp follow_safe_redirect(_url, response, _request_opts, _opts, _redirects),
    do: {:ok, response}

  defp resolve_redirect(url, location) when is_binary(location) do
    {:ok, url |> URI.merge(location) |> URI.to_string()}
  rescue
    ArgumentError -> {:error, :invalid_redirect_location}
  end

  defp circuit_key(base_url, username, opts) do
    Keyword.get(opts, :provider_id) || :erlang.phash2({base_url, username})
  end
end
