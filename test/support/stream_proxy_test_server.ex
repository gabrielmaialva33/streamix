defmodule Streamix.TestSupport.StreamProxyTestServer do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    body_counter = Keyword.get(opts, :body_counter)
    path = request_path(conn.request_path)

    case {conn.method, path} do
      {"HEAD", "/redirect-to-xtream.mp4"} ->
        conn
        |> put_resp_header(
          "location",
          "http://cdn.example.test/movie/final_user/final_pass/99807.mp4"
        )
        |> send_resp(302, "")

      {"HEAD", "/movie/final_user/final_pass/99807.mp4"} ->
        send_resp(conn, 200, "")

      {"GET", "/movie/final_user/final_pass/99807.mp4"} ->
        conn = send_chunked(conn, 200)
        stream_body(conn, body_counter, 1)

      {"HEAD", "/redirect-chain.mp4"} ->
        send_resp(conn, 200, "")

      {"GET", "/redirect-chain.mp4"} ->
        conn
        |> put_resp_header("location", "http://cdn.example.test/vauth/redirect-chain.mp4")
        |> send_resp(302, "")

      {"HEAD", "/vauth/redirect-chain.mp4"} ->
        send_resp(conn, 200, "")

      {"GET", "/vauth/redirect-chain.mp4"} ->
        conn
        |> put_resp_header("location", "http://cdn.example.test/deliver/redirect-chain.mp4")
        |> send_resp(302, "")

      {"HEAD", "/deliver/redirect-chain.mp4"} ->
        send_resp(conn, 200, "")

      {"GET", "/deliver/redirect-chain.mp4"} ->
        conn = send_chunked(conn, 200)
        stream_body(conn, body_counter, 1)

      {"HEAD", "/video.mp4"} ->
        send_resp(conn, 405, "")

      {"GET", "/video.mp4"} ->
        conn = send_chunked(conn, 200)
        stream_body(conn, body_counter, 200)

      {"HEAD", "/head-blocked.mp4"} ->
        send_resp(conn, 403, "")

      {"GET", "/head-blocked.mp4"} ->
        conn = send_chunked(conn, 200)
        stream_body(conn, body_counter, 200)

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp request_path(path) when is_binary(path) do
    case URI.parse(path) do
      %URI{path: nil} -> path
      %URI{path: parsed_path} when is_binary(parsed_path) -> parsed_path
      _ -> path
    end
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
