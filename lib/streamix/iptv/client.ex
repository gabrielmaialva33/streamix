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
          {:ok, map()} | {:error, atom() | {atom(), any()}}
  def test_connection(base_url, username, password) do
    case get_provider_info(base_url, username, password) do
      {:ok, %{"user_info" => user_info}} ->
        {:ok, normalize_user_info(user_info)}

      {:ok, info} when is_map(info) ->
        # Some providers return flat structure
        {:ok, normalize_user_info(info)}

      {:error, :unauthorized} ->
        {:error, :invalid_credentials}

      {:error, {:http_error, 404}} ->
        {:error, :invalid_url}

      {:error, %Req.TransportError{reason: :nxdomain}} ->
        {:error, :host_not_found}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    "#{base}/get.php?username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}&type=m3u_plus&output=ts"
  end

  defp build_info_url(base_url, username, password) do
    base = String.trim_trailing(base_url, "/")
    "#{base}/player_api.php?username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}"
  end
end
