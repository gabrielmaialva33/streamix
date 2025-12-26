defmodule Streamix.Iptv.XtreamClient do
  @moduledoc """
  HTTP client for Xtream Codes JSON API.

  Endpoints:
  - Account info (no action)
  - Live: get_live_categories, get_live_streams
  - VOD: get_vod_categories, get_vod_streams, get_vod_info
  - Series: get_series_categories, get_series, get_series_info
  """

  @timeout :timer.seconds(30)

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

    case Req.get(url, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

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
