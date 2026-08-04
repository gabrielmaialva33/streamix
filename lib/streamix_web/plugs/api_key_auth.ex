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

  alias Streamix.Accounts
  alias StreamixWeb.Api.V1.Response

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
          |> unauthorized(
            "missing_api_key",
            "Missing API key. Include X-API-Key header."
          )

        {:error, :invalid_key} ->
          ip = Accounts.client_ip(conn)

          :telemetry.execute(
            [:streamix, :auth, :api_key, :rejected],
            %{count: 1},
            %{ip: ip, reason: :invalid_key}
          )

          conn
          |> unauthorized("invalid_api_key", "Invalid API key.")
      end
    else
      # No API keys configured - allow all requests (dev mode)
      conn
    end
  end

  @doc """
  Returns true when the connection carries a valid X-API-Key header.

  Non-halting — safe to call from controllers (e.g. StreamController) that
  need to know whether the caller is an authorized integration (TV / mobile
  app) without running this module as a plug.

  Returns `false` when no keys are configured, the header is missing, or
  the key doesn't match.
  """
  def valid_api_key?(conn) do
    with true <- api_keys_configured?(),
         {:ok, key} <- get_api_key(conn),
         :ok <- validate_api_key(key) do
      true
    else
      _ -> false
    end
  end

  defp api_keys_configured? do
    case Application.get_env(:streamix, :api_keys, []) do
      [] -> false
      [_ | _] -> true
    end
  end

  defp get_api_key(conn) do
    # Header-only. Query string is rejected: keys end up in reverse-proxy
    # access logs, browser history, referer headers and shared dashboards.
    # Integrations that genuinely can't set a header (rare) should use a
    # short-lived signed token (`StreamixWeb.StreamToken`) instead.
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :missing_key}
    end
  end

  defp validate_api_key(key) do
    valid_keys = Application.get_env(:streamix, :api_keys, [])

    # Use secure_compare to prevent timing attacks
    if Enum.any?(valid_keys, &Plug.Crypto.secure_compare(&1, key)) do
      :ok
    else
      {:error, :invalid_key}
    end
  end

  defp unauthorized(conn, code, message) do
    conn
    |> Response.error(:unauthorized, code, message)
    |> halt()
  end
end
