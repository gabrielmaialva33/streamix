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

  alias Streamix.Iptv.Sync.Telemetry
  alias Streamix.Iptv.XtreamCircuitBreaker

  require Logger

  @timeout :timer.seconds(30)
  @max_retries 3
  @base_retry_delay 10_000

  # ============================================================================
  # Account
  # ============================================================================

  def get_account_info(url, username, password) do
    api_call(url, username, password, nil)
  end

  # ============================================================================
  # Live TV
  # ============================================================================

  def get_live_categories(url, username, password) do
    api_call(url, username, password, "get_live_categories")
  end

  def get_live_streams(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_live_streams", params)
  end

  # ============================================================================
  # VOD (Movies)
  # ============================================================================

  def get_vod_categories(url, username, password) do
    api_call(url, username, password, "get_vod_categories")
  end

  def get_vod_streams(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_vod_streams", params)
  end

  def get_vod_info(url, username, password, vod_id) do
    api_call(url, username, password, "get_vod_info", %{vod_id: vod_id})
  end

  # ============================================================================
  # Series
  # ============================================================================

  def get_series_categories(url, username, password) do
    api_call(url, username, password, "get_series_categories")
  end

  def get_series(url, username, password, opts \\ []) do
    params = if cat = opts[:category_id], do: %{category_id: cat}, else: %{}
    api_call(url, username, password, "get_series", params)
  end

  def get_series_info(url, username, password, series_id) do
    api_call(url, username, password, "get_series_info", %{series_id: series_id})
  end

  # ============================================================================
  # EPG
  # ============================================================================

  @doc """
  Fetches short EPG data for a specific stream.
  Returns program listings for the specified channel.
  """
  def get_short_epg(url, username, password, stream_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    api_call(url, username, password, "get_short_epg", %{stream_id: stream_id, limit: limit})
  end

  @doc """
  Fetches simple EPG data table for a stream.
  """
  def get_simple_data_table(url, username, password, stream_id) do
    api_call(url, username, password, "get_simple_data_table", %{stream_id: stream_id})
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

  defp api_call(base_url, username, password, action, extra_params \\ %{}) do
    url = build_url(base_url, username, password, action, extra_params)
    action_name = action || "account_info"

    # Use URL+username hash as provider identifier for circuit breaker
    provider_id = :erlang.phash2({base_url, username})

    # Check circuit breaker before making request
    case XtreamCircuitBreaker.allow_request?(provider_id) do
      :ok ->
        Telemetry.span_api_call(provider_id, action_name, fn ->
          result = do_api_call(url, 0)

          # Report result to circuit breaker
          case result do
            {:ok, _} ->
              XtreamCircuitBreaker.report_success(provider_id)

            {:error, error_type} ->
              XtreamCircuitBreaker.report_error(provider_id, categorize_error(error_type))
          end

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

  defp do_api_call(url, attempt) do
    # Use dedicated Finch pool for connection reuse during sync
    case Req.get(url,
           receive_timeout: @timeout,
           finch: Streamix.Finch,
           headers: [{"user-agent", "xciptv-v6.0.0"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 429}} when attempt < @max_retries ->
        # Rate limited - exponential backoff with jitter
        delay = @base_retry_delay * round(:math.pow(2, attempt)) + :rand.uniform(2000)

        Logger.warning(
          "[XtreamClient] Rate limited (429), retry #{attempt + 1}/#{@max_retries} in #{div(delay, 1000)}s"
        )

        Process.sleep(delay)
        do_api_call(url, attempt + 1)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        # Transport error - retry with backoff
        delay = @base_retry_delay * round(:math.pow(2, attempt)) + :rand.uniform(1000)

        Logger.warning(
          "[XtreamClient] Transport error #{inspect(reason)}, retry #{attempt + 1}/#{@max_retries}"
        )

        Process.sleep(delay)
        do_api_call(url, attempt + 1)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Categorize errors for circuit breaker metrics
  defp categorize_error({:http_error, status}) when status >= 500, do: :server_error
  defp categorize_error({:http_error, 429}), do: :rate_limited
  defp categorize_error({:http_error, status}) when status >= 400, do: :client_error
  defp categorize_error({:transport_error, :timeout}), do: :timeout
  defp categorize_error({:transport_error, _}), do: :transport_error
  defp categorize_error(_), do: :unknown

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
end
