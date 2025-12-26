defmodule Streamix.Iptv.Client do
  @moduledoc """
  HTTP client for IPTV provider APIs.

  Handles communication with Xtream Codes compatible IPTV providers,
  including connection testing, account info retrieval, and channel listing.
  """

  alias Streamix.Iptv.Parser

  # Configuration with compile-time defaults
  @config Application.compile_env(:streamix, Streamix.Iptv, [])
  defp http_timeout, do: Keyword.get(@config, :http_timeout, :timer.seconds(60))
  defp http_info_timeout, do: Keyword.get(@config, :http_info_timeout, :timer.seconds(10))

  @type channel :: Parser.channel()
  @type connection_error ::
          :invalid_credentials
          | :invalid_url
          | :host_not_found
          | :connection_refused
          | :timeout
          | :invalid_response
          | {:http_error, integer()}

  @doc """
  Fetches the channel list from an IPTV provider.

  ## Options
    * `:timeout` - Request timeout in milliseconds (default: configured http_timeout)
  """
  @spec get_channels(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [channel()]} | {:error, term()}
  def get_channels(base_url, username, password, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, http_timeout())
    url = build_playlist_url(base_url, username, password)

    case fetch_url(url, timeout) do
      {:ok, body} ->
        channels = Parser.parse(body)
        {:ok, channels}

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

    case fetch_url(url, http_info_timeout()) do
      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:ok, body} when is_binary(body) ->
        decode_json(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Tests connection to an IPTV provider and returns account info.
  Returns {:ok, info} with account details or {:error, reason}.

  Info includes:
  - :status - "Active", "Expired", etc
  - :exp_date - Expiration timestamp
  - :is_trial - Whether it's a trial account
  - :active_cons - Active connections
  - :max_connections - Max allowed connections
  """
  @spec test_connection(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, connection_error()}
  def test_connection(base_url, username, password) do
    case get_provider_info(base_url, username, password) do
      {:ok, %{"user_info" => user_info}} ->
        {:ok, normalize_user_info(user_info)}

      {:ok, info} when is_map(info) ->
        {:ok, normalize_user_info(info)}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp fetch_url(url, timeout) do
    case Req.get(url, receive_timeout: timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, info} -> {:ok, info}
      {:error, _} -> {:error, :invalid_response}
    end
  end

  defp translate_error(:unauthorized), do: :invalid_credentials
  defp translate_error({:http_error, 404}), do: :invalid_url
  defp translate_error({:transport_error, :nxdomain}), do: :host_not_found
  defp translate_error({:transport_error, :econnrefused}), do: :connection_refused
  defp translate_error({:transport_error, :timeout}), do: :timeout
  defp translate_error(:invalid_response), do: :invalid_response
  defp translate_error({:http_error, status}), do: {:http_error, status}
  defp translate_error(reason), do: reason

  defp normalize_user_info(info) do
    %{
      status: info["status"] || "unknown",
      exp_date: parse_exp_date(info["exp_date"]),
      is_trial: info["is_trial"] == "1" || info["is_trial"] == true,
      active_cons: to_integer(info["active_cons"]),
      max_connections: to_integer(info["max_connections"])
    }
  end

  defp parse_exp_date(nil), do: nil
  defp parse_exp_date(ts) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp parse_exp_date(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {unix, _} -> DateTime.from_unix!(unix)
      :error -> nil
    end
  end

  defp to_integer(nil), do: nil
  defp to_integer(n) when is_integer(n), do: n

  defp to_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp build_playlist_url(base_url, username, password) do
    base = String.trim_trailing(base_url, "/")
    user = URI.encode_www_form(username)
    pass = URI.encode_www_form(password)

    "#{base}/get.php?username=#{user}&password=#{pass}&type=m3u_plus&output=ts"
  end

  defp build_info_url(base_url, username, password) do
    base = String.trim_trailing(base_url, "/")
    user = URI.encode_www_form(username)
    pass = URI.encode_www_form(password)

    "#{base}/player_api.php?username=#{user}&password=#{pass}"
  end
end
