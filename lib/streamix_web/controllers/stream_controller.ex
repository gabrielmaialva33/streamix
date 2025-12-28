defmodule StreamixWeb.StreamController do
  @moduledoc """
  Controller for proxying IPTV streams with real streaming support.

  Supports Range requests for seeking in video players.
  """
  use StreamixWeb, :controller

  require Logger

  @request_timeout 30_000

  @doc """
  Proxies a stream URL with chunked transfer.
  Supports HTTP Range requests for seeking.
  """
  def proxy(conn, %{"url" => encoded_url}) do
    case Base.url_decode64(encoded_url, padding: false) do
      {:ok, url} ->
        stream_url(conn, url)

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid URL encoding"})
    end
  end

  def proxy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing url parameter"})
  end

  defp stream_url(conn, url) do
    # Build headers for upstream request
    upstream_headers = build_upstream_headers(conn)

    # Make streaming request to upstream
    case stream_request(url, upstream_headers) do
      {:ok, status, headers, body_stream} ->
        send_streaming_response(conn, status, headers, body_stream)

      {:error, reason} ->
        Logger.error("Stream proxy error: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to fetch stream", reason: inspect(reason)})
    end
  end

  defp build_upstream_headers(conn) do
    headers = [
      {"user-agent", "Streamix/1.0"},
      {"accept", "*/*"},
      {"connection", "keep-alive"}
    ]

    # Forward Range header if present (for seeking)
    case get_req_header(conn, "range") do
      [range] -> [{"range", range} | headers]
      _ -> headers
    end
  end

  defp stream_request(url, headers) do
    # Use Req with into: :self for streaming
    opts = [
      headers: headers,
      receive_timeout: @request_timeout,
      connect_options: [timeout: 10_000],
      redirect: true,
      max_redirects: 5,
      decode_body: false,
      into: :self
    ]

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: status, headers: resp_headers}} ->
        {:ok, status, resp_headers, &receive_chunks/0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_chunks do
    receive do
      {:data, chunk} -> {:cont, chunk}
      :done -> :halt
    after
      @request_timeout -> :halt
    end
  end

  defp send_streaming_response(conn, upstream_status, upstream_headers, body_stream) do
    # Determine response status
    status = if upstream_status == 206, do: 206, else: 200

    # Build response headers
    conn =
      conn
      |> put_resp_content_type(get_content_type(upstream_headers))
      |> put_cors_headers()
      |> put_streaming_headers()
      |> maybe_put_content_length(upstream_headers)
      |> maybe_put_content_range(upstream_headers)
      |> maybe_put_accept_ranges(upstream_headers)

    # Send chunked response
    conn = send_chunked(conn, status)

    # Stream chunks to client
    stream_chunks(conn, body_stream)
  end

  defp stream_chunks(conn, body_stream) do
    case body_stream.() do
      {:cont, chunk} ->
        case chunk(conn, chunk) do
          {:ok, conn} -> stream_chunks(conn, body_stream)
          {:error, _reason} -> conn
        end

      :halt ->
        conn
    end
  end

  defp get_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, type} -> type
      nil -> "application/octet-stream"
    end
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Range, Accept-Encoding")
    |> put_resp_header("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges")
  end

  defp put_streaming_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> put_resp_header("x-accel-buffering", "no")
  end

  defp maybe_put_content_length(conn, headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, length} -> put_resp_header(conn, "content-length", length)
      nil -> conn
    end
  end

  defp maybe_put_content_range(conn, headers) do
    case List.keyfind(headers, "content-range", 0) do
      {_, range} -> put_resp_header(conn, "content-range", range)
      nil -> conn
    end
  end

  defp maybe_put_accept_ranges(conn, headers) do
    case List.keyfind(headers, "accept-ranges", 0) do
      {_, ranges} -> put_resp_header(conn, "accept-ranges", ranges)
      nil -> put_resp_header(conn, "accept-ranges", "bytes")
    end
  end
end
