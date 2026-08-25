defmodule Streamix.Iptv.Streaming.ResponsePolicy do
  @moduledoc """
  Applies safe, consistent response headers to proxied media.

  Upstream credentials and cookies are never copied. Responses remain usable by
  browser media elements while signed or provider-specific URLs are kept out of
  shared intermediary caches.
  """

  import Plug.Conn

  @exposed_headers Enum.join(
                     [
                       "Accept-Ranges",
                       "Content-Length",
                       "Content-Range",
                       "Content-Type",
                       "ETag",
                       "Last-Modified"
                     ],
                     ", "
                   )

  @spec put_vod(Plug.Conn.t()) :: Plug.Conn.t()
  def put_vod(conn) do
    conn
    |> put_common()
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("cache-control", "private, no-store")
  end

  @spec put_live(Plug.Conn.t()) :: Plug.Conn.t()
  def put_live(conn) do
    conn
    |> put_common()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-accel-buffering", "no")
  end

  @spec put_common(Plug.Conn.t()) :: Plug.Conn.t()
  def put_common(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-expose-headers", @exposed_headers)
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> merge_vary(["Origin", "Range"])
  end

  defp merge_vary(conn, additions) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    value =
      (existing ++ additions)
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.join(", ")

    put_resp_header(conn, "vary", value)
  end
end
