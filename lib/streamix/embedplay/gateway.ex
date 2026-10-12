defmodule Streamix.Embedplay.Gateway do
  @moduledoc false

  require Logger

  alias Streamix.Embedplay
  alias Streamix.Embedplay.{HTTP, Sessions}
  alias Streamix.Hls.Gateway, as: HlsGateway

  @touch_interval_ms 60_000

  # Playlists, keys and segments are fetched, rewritten and relayed by the
  # shared `Streamix.Hls.Gateway`; this module owns what is Embedplay's own:
  # the session registry, the global fetch lease and progressive streaming.
  def fetch_resource(sid, rid, movie_id, opts \\ []) do
    with true <- Embedplay.enabled?(),
         :ok <- HlsGateway.valid_range(Keyword.get(opts, :range)),
         {:ok, resource} <- Sessions.resource(sid, rid, movie_id),
         :ok <- buffered(resource),
         {:ok, lease} <- Sessions.acquire() do
      try do
        resource
        |> HlsGateway.serve(serve_options(sid, movie_id, opts))
        |> invalidate_on_restart(sid)
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
         :ok <- HlsGateway.valid_range(range),
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
    HlsGateway.rewrite_playlist(
      body,
      base_url,
      &Sessions.register(sid, movie_id, &1),
      &resource_url.(sid, &1)
    )
  end

  # The buffered path serves playlists and HLS media only. A progressive movie
  # is never collected into memory, so it is reachable only by streaming.
  defp buffered(%{kind: :progressive}), do: {:error, :resource_not_found}
  defp buffered(_resource), do: :ok

  defp serve_options(sid, movie_id, opts) do
    resource_url = Keyword.get(opts, :resource_url)

    [
      method: Keyword.get(opts, :method),
      range: Keyword.get(opts, :range),
      http_options: Embedplay.config(:http_options, []),
      register: &Sessions.register(sid, movie_id, &1),
      resource_url: &resource_url.(sid, &1)
    ]
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
    headers = Map.put(headers, "content-type", [HlsGateway.media_type(headers)])
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
end
