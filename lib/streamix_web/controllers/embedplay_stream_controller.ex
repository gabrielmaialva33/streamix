defmodule StreamixWeb.EmbedplayStreamController do
  use StreamixWeb, :controller

  alias Streamix.Embedplay
  alias StreamixWeb.StreamToken

  def options(conn, _params), do: conn |> cors() |> send_resp(204, "")

  def master(conn, %{"token" => token}) do
    with true <- Embedplay.enabled?(),
         {:ok, movie} <- StreamToken.authorize_embedplay_movie(token) do
      if head_request?(conn) do
        conn
        |> cors()
        |> put_resp_content_type("application/vnd.apple.mpegurl")
        |> send_resp(200, "")
      else
        open_and_serve(conn, movie, token)
      end
    else
      false -> error(conn, :provider_disabled)
      {:error, reason} -> error(conn, reason)
    end
  end

  def master(conn, _), do: error(conn, :missing_token)

  def resource(conn, %{"token" => token, "session_id" => sid, "resource_id" => rid}) do
    with true <- Embedplay.enabled?(),
         {:ok, movie} <- StreamToken.authorize_embedplay_movie(token) do
      serve(conn, sid, rid, movie.id, token)
    else
      false -> error(conn, :provider_disabled)
      {:error, reason} -> error(conn, reason)
    end
  end

  def resource(conn, _), do: error(conn, :missing_token)

  defp open_and_serve(conn, movie, token) do
    case Embedplay.open_movie(movie) do
      {:ok, session} -> serve(conn, session.session_id, session.resource_id, movie.id, token)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp serve(conn, sid, rid, movie_id, token) do
    opts = [
      method: if(head_request?(conn), do: :head, else: :get),
      range: List.first(get_req_header(conn, "range")),
      resource_url: fn session, resource ->
        "/api/stream/embedplay/#{session}/#{resource}?token=#{URI.encode_www_form(token)}"
      end
    ]

    case Embedplay.fetch_resource(sid, rid, movie_id, opts) do
      {:ok, response} ->
        conn =
          Enum.reduce(response.headers, cors(conn), fn {name, values}, conn ->
            put_resp_header(conn, name, Enum.join(values, ", "))
          end)

        send_resp(conn, response.status, if(head_request?(conn), do: "", else: response.body))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp head_request?(conn), do: Map.get(conn.assigns, :original_method, conn.method) == "HEAD"

  defp cors(conn) do
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

  defp error(conn, reason) do
    {status, code} = error_status(reason)

    conn
    |> cors()
    |> put_status(status)
    |> json(%{error: %{code: code, message: "Playback request could not be completed"}})
  end

  defp error_status(:provider_disabled), do: {503, :provider_disabled}
  defp error_status(:provider_capacity_exhausted), do: {503, :provider_capacity_exhausted}
  defp error_status(:upstream_timeout), do: {504, :upstream_timeout}
  defp error_status(:missing_token), do: {400, :missing_token}
  defp error_status(:invalid_token), do: {401, :invalid_token}
  defp error_status(:token_expired), do: {401, :token_expired}
  defp error_status(:unauthorized), do: {403, :token_unauthorized}
  defp error_status(:subscription_required), do: {403, :subscription_required}
  defp error_status(:unsafe_url), do: {403, :unsafe_url}
  # `stream_unavailable` means the resolver could not extract a source on this
  # attempt. The causes observed were environmental — one offered host answered
  # 403 from this server, another yielded no independently fetchable manifest —
  # not evidence that the title has no source, so it must stay retryable: a 404
  # here would mark a recoverable title dead. It gets
  # its own code purely so the failure is countable, and 503 rather than 502
  # because the condition is expected to clear.
  defp error_status(:no_source_available), do: {503, :no_source_available}
  defp error_status(:resource_not_found), do: {404, :resource_not_found}
  defp error_status(:upstream_not_found), do: {404, :upstream_not_found}
  defp error_status(:invalid_range), do: {416, :invalid_range}
  defp error_status(:playback_restart_required), do: {409, :playback_restart_required}
  defp error_status(_), do: {502, :stream_resolution_failed}
end
