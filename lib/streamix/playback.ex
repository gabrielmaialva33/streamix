defmodule Streamix.Playback do
  @moduledoc """
  Application boundary for playability, source selection, and media delivery.

  This module owns playable-content lookup, alternate-source ordering, redirect
  resolution, prewarming, and HTTP media delivery. Modules under
  `Streamix.Iptv.Streaming` remain implementation details behind this API.
  """

  alias Streamix.Iptv.{Channels, LiveChannel, Movies, Provider, SeriesOps}

  alias Streamix.Iptv.Streaming.{
    CapacityTelemetry,
    FailoverPolicy,
    LiveProxy,
    RedirectResolver,
    SourceSelector,
    StreamErrors,
    UpstreamPolicy,
    VodMultiplexer,
    VodProxy,
    XtreamDelivery,
    XtreamHls
  }

  @type stream_error_code :: StreamErrors.code()

  @doc "Records only a definitive upstream not-found response for a VOD file, asynchronously."
  defdelegate record_vod_failure(type, id, provider_id, reason),
    to: Streamix.Iptv.Content.VodAvailability,
    as: :record_failure

  @doc "Whether a VOD item is quarantined until sync changes it or the recheck window expires."
  defdelegate vod_dead?(content), to: Streamix.Iptv.Content.VodAvailability, as: :dead?

  @doc """
  Whether `content` of `type` answered not-found recently enough to skip it:
  live channels use their 24-hour recheck window, VOD its seven-day quarantine.
  """
  @spec content_dead?(String.t() | atom(), map()) :: boolean()
  def content_dead?(type, content) when type in ["live_channel", :live_channel],
    do: Channels.dead?(content)

  def content_dead?(_type, content), do: vod_dead?(content)

  # Playability and canonical stream targets

  defdelegate get_episode_for_stream(id), to: SeriesOps
  defdelegate get_live_channel_for_stream(id), to: Channels, as: :get_for_stream
  defdelegate get_movie_for_stream(id), to: Movies, as: :get_for_stream
  defdelegate get_playable_channel(user_id, id), to: Channels, as: :get_playable
  defdelegate get_playable_episode(user_id, id), to: SeriesOps
  defdelegate get_playable_movie(user_id, id), to: Movies, as: :get_playable
  defdelegate get_playable_series(user_id, id), to: SeriesOps, as: :get_playable

  # Alternative sources and failover ordering

  defdelegate list_movie_variants(movie, user_id, opts \\ []),
    to: Movies,
    as: :list_variants

  defdelegate list_series_variants(series, user_id, opts \\ []),
    to: SeriesOps,
    as: :list_variants

  @doc """
  Builds the failover URL chain for a provider without exposing provider internals.
  """
  def provider_stream_url_chain(provider, original_url) do
    FailoverPolicy.build_url_chain(original_url, Provider.url_chain(provider))
  end

  defdelegate sort_stream_sources(sources, opts \\ []), to: SourceSelector, as: :sort
  defdelegate live_channel_stream_url(channel, provider), to: LiveChannel, as: :stream_url

  # Source resolution and prewarming

  def resolve_stream_url(url, opts \\ []) do
    RedirectResolver.resolve(url, UpstreamPolicy.with_domain_policy(opts))
  end

  @doc """
  Resolves a stream URL using the source proxy credential-exchange policy.
  """
  def resolve_stream_url_for_proxy(url, opts \\ []) do
    urls = Keyword.get(opts, :url_chain, [url])
    resolve_proxy_chain(urls, UpstreamPolicy.with_domain_policy(opts), true)
  end

  defp resolve_proxy_chain([], _opts, _all_missing?), do: {:error, :stream_resolution_failed}

  defp resolve_proxy_chain([url | rest], opts, all_missing?) do
    case RedirectResolver.resolve_for_proxy(url, opts) do
      {:ok, _url} = result ->
        result

      {:error, reason} = error ->
        all_missing? =
          all_missing? and StreamErrors.code_from_reason(reason) == :upstream_not_found

        if rest == [] do
          complete_proxy_failure(error, opts, all_missing?)
        else
          resolve_proxy_chain(rest, opts, all_missing?)
        end
    end
  end

  defp complete_proxy_failure(error, opts, true) do
    record_resolution_failure(error, opts)
    error
  end

  defp complete_proxy_failure(error, _opts, false), do: error

  @doc "Prewarms without fetching a single-use token target."
  def prewarm_stream_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
    RedirectResolver.prewarm_for_proxy_async(url, UpstreamPolicy.with_domain_policy(opts))
  end

  # HTTP media delivery

  def pipe_stream(conn, url, opts \\ []) do
    VodProxy.pipe(conn, url, UpstreamPolicy.with_domain_policy(opts))
  end

  def pipe_live_stream(conn, url, opts \\ []) do
    LiveProxy.pipe(conn, url, UpstreamPolicy.with_domain_policy(opts))
  end

  @doc """
  Streams VOD through the block multiplexer so concurrent viewers of one title
  can share upstream connections. Falls back to the direct proxy when the
  multiplexer is disabled or cannot serve the request.
  """
  @spec pipe_vod_stream(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def pipe_vod_stream(conn, url, opts \\ []) do
    opts = UpstreamPolicy.with_domain_policy(opts)

    if Application.get_env(:streamix, :vod_multiplexer_enabled, false) do
      VodMultiplexer.pipe(conn, url, opts, &VodProxy.pipe(&1, url, opts))
    else
      VodProxy.pipe(conn, url, opts)
    end
  end

  @doc """
  Starts fetching the first block of a VOD title into the block cache, so
  the play that usually follows (a title page, or the player mounting just
  before the browser's first range) begins from disk instead of waiting on
  the provider. The provider CDNs measured here take ~2 s to answer any
  request. Same cache key as `pipe_vod_stream/3`; a no-op when the
  multiplexer is off or the block is already cached or in flight.

  `opts` takes `:provider_id`, `:content_id` and `:media_type`.
  """
  @spec warm_vod_start(String.t(), keyword()) :: :ok
  def warm_vod_start(url, opts) when is_binary(url) do
    if Application.get_env(:streamix, :vod_multiplexer_enabled, false) do
      opts = UpstreamPolicy.with_domain_policy(opts)
      key = VodMultiplexer.content_key(Keyword.put(opts, :url, url))
      size = VodMultiplexer.block_size()

      VodMultiplexer.BlockFetcher.prefetch({key, 0},
        url: url,
        domain_policy: Keyword.get(opts, :domain_policy),
        provider_id: Keyword.get(opts, :provider_id),
        range_start: 0,
        range_end: size - 1
      )
    end

    :ok
  end

  def head_stream(conn, url, opts \\ []) do
    VodProxy.head(conn, url, UpstreamPolicy.with_domain_policy(opts))
  end

  # Xtream VOD delivery by container

  @doc """
  How an Xtream movie or episode reaches a player, without I/O:
  `{:hls, "m3u8"}` for HLS items served by the HLS gateway, `:probe` for a
  `direct_client_playback` provider (decided per item at play time), or
  `:proxy` for the progressive token proxy.
  """
  defdelegate xtream_delivery(provider, content), to: XtreamDelivery, as: :mode

  @doc """
  How a provider's live channels are delivered, without I/O: `:ts` (the live
  proxy, the default) or `:probe` for a `probe_live_delivery` provider, whose
  channels are probed at play time (HLS gateway, TS proxy, or unavailable).
  """
  defdelegate xtream_live_mode(provider), to: XtreamDelivery, as: :live_mode

  @doc """
  The route a player must be given for an Xtream movie or episode: `:hls`,
  `{:direct, extension}` or `:proxy`. Probes (cached) when the provider
  requires it, unless `probe: false`. URL minting uses this.
  """
  defdelegate xtream_route(provider, type, content, opts \\ []), to: XtreamDelivery, as: :route

  @doc """
  Where an Xtream item stands with the delivery probe, without probing:
  `:not_probed`, `:pending`, `:decided` or `:failed`.
  """
  defdelegate xtream_probe_state(provider, type, content), to: XtreamDelivery, as: :probe_state

  @doc """
  The upstream a gateway serves an Xtream item from: `{:ok, {:hls, root_url}}`
  (credential-bearing, server-side only) or `{:ok, {:direct, client_url,
  extension}}` (safe to hand to the client).
  """
  def resolve_xtream_delivery(provider, type, content) do
    result = XtreamDelivery.resolve(provider, type, content)

    record_resolution_failure(result,
      media_type: type,
      content_id: content.id,
      provider_id: provider.id
    )

    result
  end

  defp record_resolution_failure({:error, reason}, opts) do
    record_vod_failure(
      Keyword.get(opts, :media_type),
      Keyword.get(opts, :content_id),
      Keyword.get(opts, :provider_id),
      reason
    )
  end

  defp record_resolution_failure(_result, _opts), do: :ok

  @doc """
  Opens (or reuses) the HLS gateway session for an Xtream item, rooted at its
  credential-bearing playlist URL, which never leaves the server.
  """
  defdelegate open_xtream_hls(content, provider_id, url), to: XtreamHls, as: :open

  @doc "Fetches one opaque resource (playlist, key or segment) of an Xtream HLS session."
  defdelegate fetch_xtream_hls_resource(session_id, resource_id, content, opts \\ []),
    to: XtreamHls,
    as: :fetch_resource

  @doc """
  Fetches an Xtream HLS session's root for the master route. A live channel
  whose root is a media playlist is answered with a one-variant master that
  points at the root resource.
  """
  defdelegate fetch_xtream_hls_master(session_id, resource_id, content, opts \\ []),
    to: XtreamHls,
    as: :fetch_master

  # Stable error translation used by the web delivery layer

  defdelegate halt_stream_error(conn, code, opts \\ []), to: StreamErrors, as: :halt

  @doc """
  Records that a stream was refused for lack of upstream capacity.

  Exposed on the facade so web callers never reach into
  `Streamix.Iptv.Streaming.*` directly.
  """
  defdelegate stream_capacity_refused(dimension, metadata \\ []),
    to: CapacityTelemetry,
    as: :refused

  defdelegate stream_error_code_from_reason(reason), to: StreamErrors, as: :code_from_reason

  # GIndex stream source cache

  defdelegate get_gindex_stream_source(content_type, content_id),
    to: Streamix.Iptv.Content.GindexStream,
    as: :get_source

  defdelegate put_gindex_stream_cache(content_type, content_id, source, attrs),
    to: Streamix.Iptv.Content.GindexStream,
    as: :put_cache
end
