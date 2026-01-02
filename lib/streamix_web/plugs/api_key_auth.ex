defmodule StreamixWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  API Key authentication plug.

  Validates requests using the `X-API-Key` header against configured API keys.

  Usage in router:
    plug StreamixWeb.Plugs.ApiKeyAuth

  Configuration in config.exs:
    config :streamix, :api_keys, ["key1", "key2"]

  Or via environment variable:
    config :streamix, :api_keys, System.get_env("API_KEYS", "") |> String.split(",")
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts) do
    # Allow CORS preflight requests without API key
    conn
  end

  def call(conn, _opts) do
    # Skip auth if no API keys are configured (dev mode)
    if api_keys_configured?() do
      with {:ok, api_key} <- get_api_key(conn),
           :ok <- validate_api_key(api_key) do
        conn
      else
        {:error, :missing_key} ->
          conn
          |> unauthorized("Missing API key. Include X-API-Key header.")

        {:error, :invalid_key} ->
          Logger.warning("Invalid API key attempt from #{format_ip(conn.remote_ip)}")

          conn
          |> unauthorized("Invalid API key.")
      end
    else
      # No API keys configured - allow all requests (dev mode)
      conn
    end
  end

  defp api_keys_configured? do
    case Application.get_env(:streamix, :api_keys, []) do
      [] -> false
      [_ | _] -> true
    end
  end

  defp get_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :missing_key}
    end
  end

  defp validate_api_key(key) do
    valid_keys = Application.get_env(:streamix, :api_keys, [])

    if key in valid_keys do
      :ok
    else
      {:error, :invalid_key}
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{
      error: "Unauthorized",
      message: message
    })
    |> halt()
  end

  defp format_ip(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end
end
