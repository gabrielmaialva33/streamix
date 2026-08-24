defmodule Streamix.Playback do
  @moduledoc """
  Application boundary for playability, source selection, and media delivery.

  This module owns playable-content lookup, alternate-source ordering, redirect
  resolution, prewarming, and HTTP media delivery. Modules under
  `Streamix.Iptv.Streaming` remain implementation details behind this API.
  """

  alias Streamix.Iptv.{Channels, LiveChannel, Movies, Provider, SeriesOps}

  alias Streamix.Iptv.Streaming.{
    FailoverPolicy,
    LiveProxy,
    RedirectResolver,
    SourceSelector,
    StreamErrors,
    VodMultiplexer,
    VodProxy
  }

  @type stream_error_code :: StreamErrors.code()

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

  defdelegate resolve_stream_url(url, opts \\ []), to: RedirectResolver, as: :resolve

  @doc """
  Resolves a stream URL using the source proxy credential-exchange policy.
  """
  defdelegate resolve_stream_url_for_proxy(url, opts \\ []),
    to: RedirectResolver,
    as: :resolve_for_proxy

  @doc "Prewarms without fetching a single-use token target."
  def prewarm_stream_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
    RedirectResolver.prewarm_for_proxy_async(url, opts)
  end

  # HTTP media delivery

  defdelegate pipe_stream(conn, url, opts \\ []), to: VodProxy, as: :pipe
  defdelegate pipe_live_stream(conn, url, opts \\ []), to: LiveProxy, as: :pipe

  @doc """
  Streams VOD through the block multiplexer so concurrent viewers of one title
  can share upstream connections. Falls back to the direct proxy when the
  multiplexer is disabled or cannot serve the request.
  """
  @spec pipe_vod_stream(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def pipe_vod_stream(conn, url, opts \\ []) do
    if Application.get_env(:streamix, :vod_multiplexer_enabled, false) do
      VodMultiplexer.pipe(conn, url, opts, &VodProxy.pipe(&1, url, opts))
    else
      VodProxy.pipe(conn, url, opts)
    end
  end

  defdelegate head_stream(conn, url, opts \\ []), to: VodProxy, as: :head

  # Stable error translation used by the web delivery layer

  defdelegate halt_stream_error(conn, code, opts \\ []), to: StreamErrors, as: :halt
  defdelegate stream_error_code_from_reason(reason), to: StreamErrors, as: :code_from_reason
end
