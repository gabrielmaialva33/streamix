defmodule Streamix.TestSupport.StreamProxyTestServer do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    body_counter = Keyword.get(opts, :body_counter)
    path = request_path(conn.request_path)

    handle_request(conn, conn.method, path, body_counter)
  end

  defp handle_request(conn, "HEAD", "/redirect-to-xtream.mp4", _body_counter) do
    conn
    |> put_resp_header(
      "location",
      "http://cdn.example.test/movie/final_user/final_pass/99807.mp4"
    )
    |> send_resp(302, "")
  end

  defp handle_request(conn, "GET", "/redirect-to-xtream.mp4", _body_counter) do
    conn
    |> put_resp_header(
      "location",
      "http://cdn.example.test/movie/final_user/final_pass/99807.mp4"
    )
    |> send_resp(302, "")
  end

  defp handle_request(conn, "HEAD", "/movie/final_user/final_pass/99807.mp4", _body_counter),
    do: send_resp(conn, 200, "")

  defp handle_request(conn, "GET", "/movie/final_user/final_pass/99807.mp4", body_counter),
    do: send_stream(conn, body_counter, 1)

  defp handle_request(conn, "HEAD", "/redirect-chain.mp4", _body_counter),
    do: send_resp(conn, 200, "")

  defp handle_request(conn, "GET", "/redirect-chain.mp4", _body_counter) do
    conn
    |> put_resp_header("location", "http://cdn.example.test/vauth/redirect-chain.mp4")
    |> send_resp(302, "")
  end

  defp handle_request(conn, "HEAD", "/vauth/redirect-chain.mp4", _body_counter),
    do: send_resp(conn, 200, "")

  defp handle_request(conn, "GET", "/vauth/redirect-chain.mp4", _body_counter) do
    conn
    |> put_resp_header("location", "http://cdn.example.test/deliver/redirect-chain.mp4")
    |> send_resp(302, "")
  end

  defp handle_request(conn, "HEAD", "/deliver/redirect-chain.mp4", _body_counter),
    do: send_resp(conn, 200, "")

  defp handle_request(conn, "GET", "/deliver/redirect-chain.mp4", body_counter),
    do: send_stream(conn, body_counter, 1)

  defp handle_request(conn, "HEAD", "/video.mp4", _body_counter), do: send_resp(conn, 405, "")

  defp handle_request(conn, "GET", "/video.mp4", body_counter),
    do: send_stream(conn, body_counter, 200)

  defp handle_request(conn, "HEAD", "/head-blocked.mp4", _body_counter),
    do: send_resp(conn, 403, "")

  defp handle_request(conn, "GET", "/head-blocked.mp4", body_counter),
    do: send_stream(conn, body_counter, 200)

  defp handle_request(conn, _method, _path, _body_counter), do: send_resp(conn, 404, "not found")

  defp request_path(path) when is_binary(path) do
    case URI.parse(path).path do
      nil -> path
      parsed_path -> parsed_path
    end
  end

  defp send_stream(conn, body_counter, chunks) do
    conn = send_chunked(conn, 200)
    stream_body(conn, body_counter, chunks)
  end

  defp stream_body(conn, body_counter, remaining) when remaining > 0 do
    if body_counter, do: Agent.update(body_counter, &(&1 + 1))

    case chunk(conn, String.duplicate("a", 4_096)) do
      {:ok, conn} -> stream_body(conn, body_counter, remaining - 1)
      {:error, :closed} -> conn
      {:error, _reason} -> conn
    end
  end

  defp stream_body(conn, _body_counter, 0), do: conn
end
