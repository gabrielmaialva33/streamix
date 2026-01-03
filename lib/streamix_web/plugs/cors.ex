defmodule StreamixWeb.Plugs.CORS do
  @moduledoc """
  Custom CORS plug that reads allowed origins from application configuration.

  Configuration:
    config :streamix, :cors, origins: ["https://example.com"]

  The origins can be:
    - A list of allowed origins: ["https://example.com", "https://app.example.com"]
    - :all to allow all origins (not recommended for production)
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origins = get_allowed_origins()

    case get_req_header(conn, "origin") do
      [origin] ->
        if origin_allowed?(origin, origins) do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header(
            "access-control-allow-methods",
            "GET, POST, PUT, PATCH, DELETE, OPTIONS"
          )
          |> put_resp_header(
            "access-control-allow-headers",
            "content-type, authorization, x-requested-with, range, accept-encoding"
          )
          |> put_resp_header("access-control-allow-credentials", "true")
          |> put_resp_header("access-control-max-age", "86400")
          |> put_resp_header(
            "access-control-expose-headers",
            "content-length, content-range, accept-ranges"
          )
          |> handle_preflight()
        else
          conn
        end

      _ ->
        conn
    end
  end

  defp get_allowed_origins do
    Application.get_env(:streamix, :cors, [])[:origins] || []
  end

  defp origin_allowed?(_origin, :all), do: true
  defp origin_allowed?(origin, origins) when is_list(origins), do: origin in origins
  defp origin_allowed?(_origin, _), do: false

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
