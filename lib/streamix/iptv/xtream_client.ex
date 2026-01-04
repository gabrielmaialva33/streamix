defmodule Streamix.Iptv.XtreamClient do
  @moduledoc """
  HTTP client for Xtream Codes JSON API.

  Endpoints:
  - Account info (no action)
  - Live: get_live_categories, get_live_streams
  - VOD: get_vod_categories, get_vod_streams, get_vod_info
  - Series: get_series_categories, get_series, get_series_info
  """

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
    do_api_call(url, 0)
  end

  defp do_api_call(url, attempt) do
    # Use dedicated Finch pool for connection reuse during sync
    case Req.get(url, receive_timeout: @timeout, finch: Streamix.Finch) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 429}} when attempt < @max_retries ->
        # Rate limited - exponential backoff with jitter
        delay = @base_retry_delay * round(:math.pow(2, attempt)) + :rand.uniform(2000)
        Logger.warning("[XtreamClient] Rate limited (429), retry #{attempt + 1}/#{@max_retries} in #{div(delay, 1000)}s")
        Process.sleep(delay)
        do_api_call(url, attempt + 1)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        # Transport error - retry with backoff
        delay = @base_retry_delay * round(:math.pow(2, attempt)) + :rand.uniform(1000)
        Logger.warning("[XtreamClient] Transport error #{inspect(reason)}, retry #{attempt + 1}/#{@max_retries}")
        Process.sleep(delay)
        do_api_call(url, attempt + 1)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
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
end
