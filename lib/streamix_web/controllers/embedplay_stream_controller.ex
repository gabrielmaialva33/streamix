defmodule StreamixWeb.EmbedplayStreamController do
  use StreamixWeb, :controller

  alias Streamix.Embedplay
  alias StreamixWeb.StreamToken

  def options(conn, _params), do: conn |> cors() |> send_resp(204, "")

  def master(conn, %{"token" => token}) do
    with true <- Embedplay.enabled?(),
         {:ok, movie} <- StreamToken.authorize_embedplay_movie(token) do
      cond do
        not head_request?(conn) ->
          open_and_serve(conn, movie, token)

        # A HEAD that answered 200 while GET answered 503 made a client that
        # probes first mount its player and then fail with a generic error.
        Embedplay.degraded?(movie) ->
          error(conn, :provider_degraded)

        true ->
          conn
          |> cors()
          |> put_resp_content_type("application/vnd.apple.mpegurl")
          |> send_resp(200, "")
      end
    else
      false -> error(conn, :provider_disabled)
      {:error, reason} -> error(conn, reason)
    end
  end

  def master(conn, _), do: error(conn, :missing_token)

  # Progressive movies have their own URL because every player picks its
  # engine from the URL before fetching a byte: the web player and both TV
  # backends send any URL containing `.m3u8` to an HLS engine (AVPlay switches
  # to adaptive mode), whatever the response says. The `.mp4` suffix is the
  # contract, so MP4 bytes are never served from — or redirected to from —
  # the `.m3u8` route, and this route never serves a playlist.
  def video(conn, %{"token" => token}) do
    with true <- Embedplay.enabled?(),
         {:ok, movie} <- StreamToken.authorize_embedplay_movie(token) do
      cond do
        not head_request?(conn) ->
          stream_video(conn, movie, true)

        # The TV HTML5 backend probes with HEAD and mounts <video> on a 200, so
        # HEAD has to report the same degraded state a GET would; otherwise the
        # viewer gets a generic playback failure instead of "unavailable".
        Embedplay.degraded?(movie) ->
          error(conn, :provider_degraded)

        # Resolving starts a browser for about ten seconds; HEAD only has to
        # name the format, which the TV HTML5 backend uses to choose native
        # playback. The length is unknown until resolution, so it is omitted.
        true ->
          conn
          |> cors()
          |> put_resp_content_type("video/mp4", nil)
          |> put_resp_header("accept-ranges", "bytes")
          |> send_resp(200, "")
      end
    else
      false -> error(conn, :provider_disabled)
      {:error, reason} -> error(conn, reason)
    end
  end

  def video(conn, _), do: error(conn, :missing_token)

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
    case open(movie, :hls) do
      {:ok, session} -> serve(conn, session.session_id, session.resource_id, movie.id, token)
      {:error, reason} -> error(conn, reason)
    end
  end

  # Each route serves exactly one delivery format. A movie whose current
  # source is in the other one fails cleanly instead of being cross-served,
  # because the player already chose its engine from the URL.
  defp open(movie, kind) do
    case Embedplay.open_movie(movie) do
      {:ok, session} ->
        if Map.get(session, :kind, :hls) == kind,
          do: {:ok, session},
          else: {:error, :stream_format_mismatch}

      error ->
        error
    end
  end

  defp stream_video(conn, movie, renew?) do
    range = List.first(get_req_header(conn, "range"))

    case open(movie, :mp4) do
      {:ok, session} ->
        conn
        |> stream_session(session, movie.id, range)
        |> finish_video(conn, movie, renew? and from_start?(range))

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp stream_session(conn, session, movie_id, range) do
    Embedplay.stream_resource(
      session.session_id,
      session.resource_id,
      movie_id,
      [range: range],
      conn,
      &write_media/2
    )
  end

  defp finish_video({:ok, conn}, _conn, _movie, _renew?), do: conn
  defp finish_video({:error, :upstream_aborted, conn}, _conn, _movie, _renew?), do: conn

  # The gateway already invalidated the session whose source stopped
  # authorizing. A read from byte 0 parses the file afresh, so it may continue
  # on a new resolution within this same request, sparing a new viewer a
  # failed first play on a stale cached source. A later range is never retried
  # this way: a new resolution might be a different file, whose bytes would
  # not continue the ones the player already holds.
  defp finish_video({:error, :playback_restart_required}, conn, movie, true),
    do: stream_video(conn, movie, false)

  defp finish_video({:error, reason}, conn, _movie, _renew?), do: error(conn, reason)

  defp from_start?(nil), do: true
  defp from_start?(range), do: String.starts_with?(range, "bytes=0-")

  defp write_media({:start, status, headers}, conn) do
    conn =
      headers
      |> Enum.reduce(cors(conn), fn {name, values}, conn ->
        put_resp_header(conn, name, Enum.join(values, ", "))
      end)
      # A compressed or otherwise transformed body would no longer be the
      # byte range its `Content-Range` claims.
      |> put_resp_header("cache-control", "private, no-store, no-transform")
      |> close_after_body()

    {:cont, send_chunked(conn, status)}
  end

  # A client that went away (a seek, a closed tab) halts the transfer, which
  # stops the upstream read instead of draining the rest of the movie.
  defp write_media({:data, data}, conn) do
    case chunk(conn, data) do
      {:ok, conn} -> {:cont, conn}
      {:error, _client_gone} -> {:halt, conn}
    end
  end

  # If the upstream fails mid-body, the response ends short of its declared
  # length. On HTTP/1.x a kept-alive socket would leave the player waiting for
  # bytes that never come until an idle timeout; closing it after the body
  # makes the truncation visible at once, so the player re-requests the range.
  # HTTP/2 already treats a body shorter than its declared length as an error.
  # Reuse costs little here: a seek abandons the old response anyway.
  defp close_after_body(conn) do
    if get_http_protocol(conn) == :"HTTP/2",
      do: conn,
      else: put_resp_header(conn, "connection", "close")
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
  # Resolution is systematically failing upstream, so playback is refused
  # before a resolution starts. 503 because a health probe clears it.
  defp error_status(:provider_degraded), do: {503, :provider_degraded}
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
  # The resolver no longer recognises the upstream page, so every title fails
  # alike until its adapter is fixed. 503 because that is expected to clear,
  # and a code of its own so the systemic case is never read as per-title.
  defp error_status(:resolver_outdated), do: {503, :resolver_outdated}
  # The upstream challenged the resolver's browser. It is never solved, so the
  # title cannot play now; 503 because the upstream may stop challenging.
  defp error_status(:challenge_required), do: {503, :challenge_required}
  # The movie's current source is HLS on the MP4 route or MP4 on the HLS
  # route. The player already chose its engine from the URL, so the bytes are
  # not cross-served. Catalog URLs name the MP4 route, the only format the
  # usable upstream delivers; an HLS-only resolution has no playable URL.
  defp error_status(:stream_format_mismatch), do: {409, :stream_format_mismatch}
  defp error_status(_), do: {502, :stream_resolution_failed}
end
