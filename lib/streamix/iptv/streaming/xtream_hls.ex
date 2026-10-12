defmodule Streamix.Iptv.Streaming.XtreamHls do
  @moduledoc """
  HLS gateway for Xtream content delivered as HLS: VOD whose
  `container_extension` is `m3u8` (or that a delivery probe found to be HLS),
  and live channels of `probe_live_delivery` providers whose probe found HLS.

  Such an item is not one byte-range file: its Xtream URL
  (`/movie/<user>/<pass>/<id>.m3u8`, `/series/…` for episodes, `/live/…` for
  channels) redirects to a playlist whose variants, audio renditions and
  segments usually live on other hosts. Proxying it as a single file — the progressive token proxy —
  can only time out. Instead this module opens a session whose registry root
  is that URL and serves every playlist, key and segment through the shared
  `Streamix.Hls.Gateway`: playlists are rewritten so each reference becomes an
  opaque Streamix resource URL, and media is relayed under a safe type.

  The source is known up front, so there is no resolver and no health
  monitor: opening a session just registers the URL. Upstream MIME types are
  ignored for classification (measured: variants as `text/plain`, MPEG-TS
  segments as `application/javascript`); the registered role or an `#EXTM3U`
  body decides, and a visibly MPEG-TS body is labelled `video/mp2t`.

  ## Keeping up with real time

  Measured against the production CDN, a 720p media playlist (2,646 two-second
  segments, 653 KB) took 5–8 s to fetch, and a cold segment 2–6 s to its first
  byte, while a warm one took well under a second. So:

    * a VOD playlist (a master, or a media playlist with `#EXT-X-ENDLIST`) is
      immutable: after its first fetch the session keeps it as a template and
      renders it for every later request, including the refetch a player
      makes on seek. It is never fetched twice in a session;
    * segments go through `Streamix.Hls.SegmentCache` (single-flight, short
      TTL, bounded memory), and a request for segment N prefetches the next
      `prefetch_segments` (3) of the same playlist, with at most
      `prefetch_concurrency` (3) prefetches in flight per session — a
      player-style forward buffer: each segment is fetched once, over one
      ordinary connection, under the per-provider lease. Segments are never
      split into byte ranges fetched in parallel;
    * upstream requests share the keep-alive `Streamix.HlsFinch` pool, and a
      media fetch may take up to `media_timeout_ms` (90 s) in total, because
      the CDN serves each connection at roughly 0.5–1 Mbit/s.

  ## Live

  A live playlist is never cached: every refresh is fetched upstream (with a
  short `live_playlist_timeout_ms`, default 8 s) and rewritten, and the
  session's registry keeps only a sliding window of references. Every viewer
  of a channel shares the session and, through `Streamix.Hls.SegmentCache`,
  one upstream fetch per segment; the lookahead is at most
  `live_prefetch_segments` (1) segment. When a channel's root is a media
  playlist (no variants), the master route answers a one-variant master that
  points at the root resource, so the player's periodic refreshes use the
  resource route and its token policy instead of restarting the playback.

  Requests use the provider-facing User-Agent, validate every redirect hop
  against SSRF and run under a per-provider fetch lease (see
  `Streamix.Iptv.Streaming.XtreamHls.Sessions`). The Xtream URL embeds the
  account password: it never leaves this process and is never logged.
  """

  alias Streamix.Hls.{Gateway, SegmentCache}
  alias Streamix.Iptv.Streaming.UpstreamPolicy
  alias Streamix.Iptv.Streaming.XtreamHls.Sessions

  @type content :: Sessions.content()

  @doc """
  Opens (or reuses) the playback session for `content`, rooted at its Xtream
  playlist `url`. Returns the opaque session and root resource identifiers.
  """
  @spec open(content(), integer(), String.t()) ::
          {:ok, %{session_id: String.t(), resource_id: String.t()}} | {:error, atom()}
  def open(content, provider_id, url) when is_binary(url),
    do: Sessions.open(content, provider_id, url)

  @doc """
  Fetches one registered resource of a session opened for `content`.

  Options: `:method` (`:get`/`:head`), `:range` (one byte range) and
  `:resource_url` (`fn session_id, resource_id -> client_url end`, used for
  every reference of a rewritten playlist).

  An upstream 401/403/410 invalidates the whole session and returns
  `{:error, :playback_restart_required}`; the next master request opens a
  fresh one.
  """
  def fetch_resource(session_id, resource_id, content, opts \\ []) do
    with :ok <- Gateway.valid_range(Keyword.get(opts, :range)),
         {:ok, resource, session} <- Sessions.resource(session_id, resource_id, content) do
      resource = Map.put(resource, :headers, [{"user-agent", UpstreamPolicy.user_agent()}])
      serve_opts = serve_options(session_id, content, session, opts)

      cond do
        session.template != nil ->
          {:ok, cached_playlist(session.template, serve_opts)}

        shared_segment?(resource, opts) ->
          prefetch_after(session_id, resource_id, session, serve_opts)

          resource.url
          |> SegmentCache.fetch(upstream(session, resource, serve_opts), timeout: fetch_timeout())
          |> invalidate_on_restart(session_id)

        true ->
          upstream(session, resource, serve_opts).()
          |> remember_playlist(session_id, resource_id, session)
          |> invalidate_on_restart(session_id)
      end
    end
  end

  @doc """
  Fetches a session's root for the master route.

  For a live channel whose root is a media playlist, the answer is a
  one-variant master that points at the root resource: players then reload
  the live playlist through the resource route (pinned to the session, with
  the resource token policy) instead of re-running the start of playback on
  every refresh. Everything else is `fetch_resource/4` of the root.
  """
  def fetch_master(session_id, resource_id, {type, _id} = content, opts \\ []) do
    with {:ok, response} <- fetch_resource(session_id, resource_id, content, opts) do
      if type == :channel and live_media_playlist?(response) do
        {:ok, live_master(Keyword.fetch!(opts, :resource_url).(session_id, resource_id))}
      else
        {:ok, response}
      end
    end
  end

  @doc "Drops a session and its resource graph."
  defdelegate invalidate(session_id), to: Sessions

  defp live_media_playlist?(%{headers: headers, body: body}) do
    Map.get(headers, "content-type") == ["application/vnd.apple.mpegurl"] and
      not String.contains?(body, "#EXT-X-STREAM-INF")
  end

  # BANDWIDTH is required on a variant; with a single variant it only seeds
  # the player's first bandwidth estimate. The measured channels run at
  # roughly 2.3–3.3 Mbit/s.
  defp live_master(root_url) do
    bandwidth = Sessions.config(:live_bandwidth, 3_000_000)

    Gateway.playlist_response("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=#{bandwidth}\n#{root_url}\n")
  end

  defp cached_playlist(template, serve_opts) do
    if Keyword.get(serve_opts, :method) == :head,
      do: Gateway.manifest_head(),
      else:
        Gateway.playlist_response(
          Gateway.render_template(template, Keyword.fetch!(serve_opts, :resource_url))
        )
  end

  # A master (no `#EXTINF`) or a media playlist with `#EXT-X-ENDLIST` cannot
  # change during a VOD session, so its template is kept and never refetched.
  # A live playlist is never kept; only its latest segment order is.
  defp remember_playlist({:ok, %{template: template, body: body} = response}, sid, rid, session) do
    immutable? =
      not session.live? and
        (String.contains?(body, "#EXT-X-ENDLIST") or not String.contains?(body, "#EXTINF"))

    Sessions.put_playlist(sid, rid, template, immutable?)
    {:ok, Map.delete(response, :template)}
  end

  defp remember_playlist(result, _sid, _rid, _session), do: result

  # Whole GETs of media go through the shared single-flight cache; a range,
  # a HEAD or a playlist never does.
  defp shared_segment?(%{kind: :media}, opts),
    do: Keyword.get(opts, :range) == nil and Keyword.get(opts, :method) in [nil, :get]

  defp shared_segment?(_resource, _opts), do: false

  # `target` is the requested segment (it moves the playhead) or `:continue`
  # (a prefetch finished and its slot is free again).
  defp prefetch_after(session_id, target, session, serve_opts) do
    depth =
      if session.live?,
        do: Sessions.config(:live_prefetch_segments, 1),
        else: Sessions.config(:prefetch_segments, 3)

    if depth > 0 do
      session_id
      |> Sessions.claim_prefetch(target, depth, &SegmentCache.cached?/1)
      |> Enum.each(&prefetch(session_id, session, &1, serve_opts))
    end
  end

  defp prefetch(session_id, session, resource, serve_opts) do
    resource = Map.put(resource, :headers, [{"user-agent", UpstreamPolicy.user_agent()}])
    serve_opts = Keyword.merge(serve_opts, method: :get, range: nil)

    Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
      try do
        SegmentCache.fetch(resource.url, upstream(session, resource, serve_opts),
          timeout: fetch_timeout()
        )
      after
        Sessions.release_prefetch(session_id, resource.id)
      end

      # Refill the window only after a segment was stored: a failure, or a
      # body the cache would not keep, must never turn into a retry loop.
      if SegmentCache.cached?(resource.url),
        do: prefetch_after(session_id, :continue, session, serve_opts)
    end)
  end

  defp upstream(session, resource, serve_opts) do
    fn -> leased(session.provider_id, fn -> Gateway.serve(resource, serve_opts) end) end
  end

  defp leased(provider_id, fun) do
    case Sessions.acquire(provider_id) do
      {:ok, lease} ->
        try do
          fun.()
        after
          Sessions.release(lease)
        end

      error ->
        error
    end
  end

  defp serve_options(session_id, content, session, opts) do
    resource_url = Keyword.fetch!(opts, :resource_url)

    [
      method: Keyword.get(opts, :method),
      range: Keyword.get(opts, :range),
      http_options: http_options(),
      sniff_media: true,
      media_timeout: media_timeout_ms(),
      # A live playlist that does not answer quickly is stale anyway.
      playlist_timeout: if(session.live?, do: Sessions.config(:live_playlist_timeout_ms, 8_000)),
      register: &Sessions.register(session_id, content, &1),
      resource_url: &resource_url.(session_id, &1)
    ]
  end

  # Upstream connections are kept alive in a dedicated pool; tests route
  # requests to a stub through `:http_options` instead.
  defp http_options do
    case Sessions.config(:http_options, []) do
      [] -> [finch: [name: Streamix.HlsFinch, pool_timeout: 5_000]]
      options -> options
    end
  end

  defp media_timeout_ms, do: Sessions.config(:media_timeout_ms, 90_000)
  defp fetch_timeout, do: Sessions.config(:lease_wait_ms, 5_000) + media_timeout_ms()

  defp invalidate_on_restart({:error, :playback_restart_required} = error, session_id) do
    Sessions.invalidate(session_id)
    error
  end

  defp invalidate_on_restart(result, _session_id), do: result
end
