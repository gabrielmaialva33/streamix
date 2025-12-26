defmodule Streamix.Iptv.Client do
  @moduledoc """
  HTTP client for IPTV provider APIs.
  """

  alias Streamix.Iptv.Parser

  @doc """
  Fetches the channel list from an IPTV provider.

  ## Options
    * `:timeout` - Request timeout in milliseconds (default: 60_000)
  """
  @spec get_channels(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Parser.channel()]} | {:error, term()}
  def get_channels(base_url, username, password, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    url = build_playlist_url(base_url, username, password)

    case Req.get(url, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} ->
        channels = Parser.parse(body)
        {:ok, channels}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets provider info (account status, expiry, etc).
  """
  @spec get_provider_info(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_provider_info(base_url, username, password) do
    url = build_info_url(base_url, username, password)

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, info} -> {:ok, info}
          {:error, _} -> {:error, :invalid_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Tests connection to an IPTV provider.
  """
  @spec test_connection(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def test_connection(base_url, username, password) do
    case get_provider_info(base_url, username, password) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_playlist_url(base_url, username, password) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/get.php?username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}&type=m3u_plus&output=ts"
  end

  defp build_info_url(base_url, username, password) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/player_api.php?username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}"
  end
end
