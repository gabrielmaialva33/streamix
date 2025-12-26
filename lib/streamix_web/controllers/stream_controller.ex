defmodule StreamixWeb.StreamController do
  @moduledoc """
  Controller for proxying IPTV streams with caching.

  Provides buffered streaming to reduce client-side buffering issues.
  """
  use StreamixWeb, :controller

  alias Streamix.Iptv.StreamProxy

  @doc """
  Proxies a stream URL with caching.

  The URL should be passed as a base64-encoded query parameter.
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
    content_type = StreamProxy.content_type_for_url(url)

    case StreamProxy.stream(url) do
      {:ok, :cached, data} ->
        conn
        |> put_resp_headers(StreamProxy.stream_headers(content_type))
        |> send_resp(200, data)

      {:error, {:http_error, status}} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Upstream server returned HTTP #{status}"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to fetch stream", reason: inspect(reason)})
    end
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_resp_header(conn, key, value)
    end)
  end
end
