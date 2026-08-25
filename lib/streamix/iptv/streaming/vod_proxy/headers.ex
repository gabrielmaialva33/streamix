defmodule Streamix.Iptv.Streaming.VodProxy.Headers do
  alias Streamix.Iptv.Streaming.ResponsePolicy
  @moduledoc false

  alias Plug.Conn
  alias Streamix.Iptv.Streaming.UpstreamPolicy

  @forwardable_request_headers ~w(range if-range if-none-match if-modified-since)
  @forwardable_response_headers ~w(
    content-type content-length content-range accept-ranges
    last-modified etag
  )

  @spec request(Conn.t(), non_neg_integer()) :: [{String.t(), String.t()}]
  def request(conn, bytes_sent) do
    base = [
      {"user-agent", UpstreamPolicy.user_agent()},
      {"accept", "*/*"},
      {"connection", "close"}
    ]

    range_override? = bytes_sent > 0

    forwardable =
      if range_override?,
        do: @forwardable_request_headers -- ["range"],
        else: @forwardable_request_headers

    forwarded =
      Enum.reduce(forwardable, base, fn name, headers ->
        case Conn.get_req_header(conn, name) do
          [value | _rest] -> [{name, value} | headers]
          [] -> headers
        end
      end)

    if range_override? do
      [{"range", "bytes=#{bytes_sent}-"} | forwarded]
    else
      forwarded
    end
  end

  @spec send_head(Conn.t(), Conn.status(), [{String.t(), String.t()}]) :: Conn.t()
  def send_head(conn, status, upstream_headers) do
    conn
    |> copy_response(upstream_headers, [])
    |> ensure_accept_ranges()
    |> put_cors()
    |> Conn.send_resp(status, "")
  end

  @spec send_chunked(Conn.t(), Conn.status(), [{String.t(), String.t()}], boolean()) ::
          Conn.t()
  def send_chunked(conn, status, upstream_headers, attempting_resume?) do
    skip = if attempting_resume?, do: ["content-length", "content-range"], else: []

    conn
    |> copy_response(upstream_headers, skip)
    |> ensure_accept_ranges()
    |> put_cors()
    |> Conn.send_chunked(status)
  end

  defp copy_response(conn, upstream_headers, skip) do
    Enum.reduce(@forwardable_response_headers -- skip, conn, fn name, acc ->
      case List.keyfind(upstream_headers, name, 0) do
        {^name, value} -> Conn.put_resp_header(acc, name, value)
        _missing -> acc
      end
    end)
  end

  defp ensure_accept_ranges(conn) do
    if Conn.get_resp_header(conn, "accept-ranges") == [] do
      Conn.put_resp_header(conn, "accept-ranges", "bytes")
    else
      conn
    end
  end

  defp put_cors(conn) do
    ResponsePolicy.put_vod(conn)
  end
end
