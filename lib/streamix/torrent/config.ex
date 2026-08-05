defmodule Streamix.Torrent.Config do
  @moduledoc false

  @default [enabled: false]

  @spec enabled?() :: boolean()
  def enabled?, do: get()[:enabled] == true

  @spec rqbit_url!() :: String.t()
  def rqbit_url! do
    case get()[:rqbit_url] do
      url when is_binary(url) and url != "" -> url
      _ -> raise ArgumentError, "missing :rqbit_url in :torrent_provider configuration"
    end
  end

  @spec rqbit_auth_secret() :: String.t() | nil
  def rqbit_auth_secret do
    case get()[:rqbit_auth_secret] do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp get, do: Application.get_env(:streamix, :torrent_provider, @default)
end
