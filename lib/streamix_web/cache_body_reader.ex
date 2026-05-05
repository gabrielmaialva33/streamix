defmodule StreamixWeb.CacheBodyReader do
  @moduledoc """
  Plug.Parsers body reader that keeps the raw request body for signed webhooks.
  """

  import Plug.Conn

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache_body(conn, body)}
      {:more, body, conn} -> {:more, body, cache_body(conn, body)}
      error -> error
    end
  end

  defp cache_body(conn, body) do
    assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
  end
end
