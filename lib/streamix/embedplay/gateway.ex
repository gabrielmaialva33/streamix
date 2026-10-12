defmodule Streamix.Embedplay.Gateway do
  @moduledoc false

  require Logger

  alias Streamix.Embedplay
  alias Streamix.Embedplay.{HLS, HTTP, Sessions}

  @media_types ~w(video/mp2t video/mp4 audio/mp4 audio/aac audio/mpeg text/vtt application/octet-stream)
  @touch_interval_ms 60_000

  def fetch_resource(sid, rid, movie_id, opts \\ []) do
    with true <- Embedplay.enabled?(),
         :ok <- valid_range(Keyword.get(opts, :range)),
         {:ok, resource} <- Sessions.resource(sid, rid, movie_id),
         :ok <- buffered(resource),
         {:ok, lease} <- Sessions.acquire() do
      try do
        fetch(resource, sid, movie_id, opts)
      after
        Sessions.release(lease)
      end
    else
      false -> {:error, :provider_disabled}
      error -> error
    end
  end

  @doc """
  Streams a progressive (single-file MP4) resource through `sink`, the
  caller's response writer: `{:start, status, headers}` once, then
  `{:data, chunk}`, each answered with `{:cont, acc}` or `{:halt, acc}`.

  The client's single `Range` (or none) goes upstream unchanged, and the
  upstream status, `Content-Range`, `Content-Length` and `Accept-Ranges` come
  back unchanged, so seeking keeps exact HTTP range semantics on every player.
  The movie is never collected: each chunk is written to the client before the
  next one is read from upstream, so a request holds one socket read of a
  1–2 GB file at a time, and a slow client slows the upstream read instead of
  growing a buffer. A client that disconnects makes the sink halt, which stops
  the upstream read and closes that connection.

  Buffering a bounded window per request (answering a wider range with a
  shorter `206`) was the alternative. It was rejected because it rewrites
  range semantics — a request without `Range` would get a `206`, which is only
  valid in reply to a range request and whose handling by Samsung AVPlay is
  unverified — and it delays the first byte by a whole window download. The
  cost of streaming is that a transfer keeps its fetch lease for as long as
  the player keeps the response open (see the lease note in `Sessions`).

  Returns `{:ok, acc}` once a response started, `{:error, :upstream_aborted,
  acc}` if the upstream broke after that, or `{:error, reason}` when nothing
  was sent and the caller can still answer with an error.
  """
  def stream_resource(sid, rid, movie_id, opts, acc, sink) do
    range = Keyword.get(opts, :range)

    with true <- Embedplay.enabled?(),
         :ok <- valid_range(range),
         {:ok, %{kind: :progressive} = resource} <- Sessions.resource(sid, rid, movie_id),
         {:ok, lease} <- Sessions.acquire() do
      try do
        state = %{acc: acc, touched_at: System.monotonic_time(:millisecond)}

        resource.url
        |> HTTP.stream(resource.headers, [range: range], state, &relay(&1, &2, sink, sid, range))
        |> unwrap_stream()
        |> invalidate_on_restart(sid)
      after
        Sessions.release(lease)
      end
    else
      false -> {:error, :provider_disabled}
      {:ok, _not_progressive} -> {:error, :resource_not_found}
      error -> error
    end
  end

  def rewrite_playlist(body, base_url, sid, movie_id, resource_url) do
    with {:ok, nodes} <- HLS.parse(body, base_url),
         resources = for({:resource, url, kind} <- nodes, do: {url, kind}),
         {:ok, ids} <- Sessions.register(sid, movie_id, Enum.uniq(resources)) do
      mapping = Map.new(Enum.zip(Enum.uniq(resources), ids))

      rewritten =
        Enum.map(nodes, fn
          {:resource, url, kind} -> resource_url.(sid, Map.fetch!(mapping, {url, kind}))
          text -> text
        end)

      {:ok, IO.iodata_to_binary(rewritten)}
    end
  end

  # The buffered path serves playlists and HLS media only. A progressive movie
  # is never collected into memory, so it is reachable only by streaming.
  defp buffered(%{kind: :progressive}), do: {:error, :resource_not_found}
  defp buffered(_resource), do: :ok

  defp fetch(resource, sid, movie_id, opts) do
    if resource.kind == :playlist and Keyword.get(opts, :method) == :head do
      manifest_head()
    else
      fetch_opts =
        if resource.kind == :playlist, do: [], else: Keyword.take(opts, [:range, :method])

      case HTTP.fetch(resource.url, resource.headers, fetch_opts) do
        {:ok, response} -> prepare_response(response, resource, sid, movie_id, opts)
        error -> invalidate_on_restart(error, sid)
      end
    end
  end

  # An upstream 401/403/410 means the resolved source stopped authorizing us.
  # The whole session goes, so no identifier is ever silently rebound to
  # different bytes; the next open resolves afresh.
  defp invalidate_on_restart({:error, :playback_restart_required} = error, sid) do
    Sessions.invalidate(sid)
    error
  end

  defp invalidate_on_restart(result, _sid), do: result

  # `206` is only valid in reply to a range request. An upstream that sends
  # one anyway, or a `206` without its `Content-Range`, is refused while the
  # client can still get a clean error.
  defp relay({:start, 206, _headers}, _state, _sink, _sid, nil),
    do: {:error, :upstream_unavailable}

  defp relay({:start, 206, headers}, _state, _sink, _sid, _range)
       when not is_map_key(headers, "content-range"),
       do: {:error, :upstream_unavailable}

  defp relay({:start, status, headers}, state, sink, _sid, _range) do
    {action, acc} = sink.({:start, status, media_headers(status, headers)}, state.acc)
    {action, %{state | acc: acc}}
  end

  defp relay({:data, chunk}, state, sink, sid, _range) do
    {action, acc} = sink.({:data, chunk}, state.acc)
    {action, keep_alive(%{state | acc: acc}, sid)}
  end

  # One transfer can outlast the session idle clock, so activity is reported
  # while bytes flow — at most once a minute, off the GenServer's call path.
  defp keep_alive(state, sid) do
    now = System.monotonic_time(:millisecond)

    if now - state.touched_at >= @touch_interval_ms do
      Sessions.touch(sid)
      %{state | touched_at: now}
    else
      state
    end
  end

  defp media_headers(status, headers) do
    headers = Map.put(headers, "content-type", [media_type(headers)])
    if status == 206, do: Map.put(headers, "accept-ranges", ["bytes"]), else: headers
  end

  defp unwrap_stream({:ok, state}), do: {:ok, state.acc}

  # The status line and part of the body are already with the client, so
  # there is no error left to send. The response ends short of its declared
  # length, which players treat as an interrupted transfer and re-request.
  defp unwrap_stream({:error, :upstream_aborted, state}) do
    Logger.warning("[Embedplay] progressive upstream failed mid-response")
    {:error, :upstream_aborted, state.acc}
  end

  defp unwrap_stream(error), do: error

  defp prepare_response(response, resource, sid, movie_id, opts) do
    if resource.kind == :playlist or HLS.playlist?(response.body) do
      with {:ok, body} <-
             rewrite_playlist(
               response.body,
               response.url,
               sid,
               movie_id,
               Keyword.fetch!(opts, :resource_url)
             ) do
        {:ok,
         %{
           status: 200,
           body: body,
           headers: %{"content-type" => ["application/vnd.apple.mpegurl"]}
         }}
      end
    else
      headers = Map.put(response.headers, "content-type", [media_type(response.headers)])
      {:ok, %{status: response.status, body: response.body, headers: headers}}
    end
  end

  # Upstream content types are advisory. Anything outside the allowlist — a
  # missing header, a parameterized type, or HTML pretending to be a segment —
  # collapses to an opaque download so the browser never interprets it.
  defp media_type(headers) do
    declared =
      case headers |> Map.get("content-type", []) |> List.first() do
        type when is_binary(type) -> type |> String.split(";") |> hd() |> String.downcase()
        _ -> nil
      end

    if declared in @media_types, do: declared, else: "application/octet-stream"
  end

  defp manifest_head do
    {:ok,
     %{status: 200, body: "", headers: %{"content-type" => ["application/vnd.apple.mpegurl"]}}}
  end

  defp valid_range(nil), do: :ok

  defp valid_range(range) when is_binary(range) and byte_size(range) <= 80 do
    if Regex.match?(~r/^bytes=(?:\d+-\d*|-\d+)$/, range),
      do: :ok,
      else: {:error, :invalid_range}
  end

  defp valid_range(_), do: {:error, :invalid_range}
end
