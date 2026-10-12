defmodule StreamixWeb.HlsResponse do
  @moduledoc """
  Response plumbing shared by the HLS gateway controllers
  (`StreamixWeb.EmbedplayStreamController`, `StreamixWeb.XtreamHlsController`).

  Every gateway response — playlist, segment or error — is CORS-open (players
  load it cross-origin with `fetch`/XHR), uncacheable, `nosniff`, and carries
  a sandbox CSP, so an upstream body that slipped past the media allowlist
  still cannot run in the Streamix origin.
  """

  import Plug.Conn

  @doc "Puts the gateway's CORS and safety headers."
  @spec cors(Plug.Conn.t()) :: Plug.Conn.t()
  def cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Range, Content-Type")
    |> put_resp_header(
      "access-control-expose-headers",
      "Content-Range, Accept-Ranges, Content-Length"
    )
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
  end

  @doc """
  Whether the client sent `HEAD`. `Plug.Head` rewrites the method to `GET`
  before the router, so the preserved original method is read.
  """
  @spec head_request?(Plug.Conn.t()) :: boolean()
  def head_request?(conn), do: Map.get(conn.assigns, :original_method, conn.method) == "HEAD"

  @doc "The request's method as a gateway fetch option."
  @spec method(Plug.Conn.t()) :: :get | :head
  def method(conn), do: if(head_request?(conn), do: :head, else: :get)

  @doc "The client's `Range` header, if any."
  @spec range(Plug.Conn.t()) :: String.t() | nil
  def range(conn), do: List.first(get_req_header(conn, "range"))

  @doc "Sends a prepared gateway response (`%{status:, headers:, body:}`)."
  @spec send_gateway_response(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def send_gateway_response(conn, response) do
    conn =
      Enum.reduce(response.headers, cors(conn), fn {name, values}, conn ->
        put_resp_header(conn, name, Enum.join(values, ", "))
      end)

    send_resp(conn, response.status, if(head_request?(conn), do: "", else: response.body))
  end
end
