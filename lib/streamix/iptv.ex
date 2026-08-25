defmodule Streamix.Iptv do
  @moduledoc """
  Compatibility facade and internal namespace for the historical IPTV API.

  New delivery-layer code must use the focused application boundaries:

    * `Streamix.Catalog` — catalog reads and display metadata
    * `Streamix.Search` — catalog search and public discovery
    * `Streamix.Library` — favorites, history, and playback progress
    * `Streamix.Playback` — playability, source selection, and media delivery
    * `Streamix.Providers` — provider lifecycle, health, and synchronization
    * `Streamix.Guide` — EPG synchronization and TV-guide queries

  This module remains as a compatibility layer while implementation ownership
  moves incrementally behind those boundaries. Modules under `Streamix.Iptv.*`
  are implementation details and must not be consumed by controllers or
  LiveViews directly.
  """

  alias Streamix.Catalog, as: CatalogBoundary
  alias Streamix.{Guide, Library, Search}
  alias Streamix.Playback, as: PlaybackBoundary
  alias Streamix.Providers, as: ProviderBoundary

  alias Streamix.Iptv.{
    Catalog,
    Channels,
    Movies,
    Provider,
    SeriesOps
  }

  alias Streamix.Iptv.Streaming.StreamErrors

  # =============================================================================
  # Favorites (catalog_item_id)
  # =============================================================================
  defdelegate list_favorites(user_id, opts \\ []), to: Library
  defdelegate list_home_favorites(user_id, opts \\ []), to: Library
  defdelegate favorite?(user_id, content_type, content_id), to: Library
  defdelegate count_favorites_by_type(user_id, opts \\ []), to: Library
  defdelegate list_favorite_ids(user_id, content_type, content_ids \\ nil), to: Library
  defdelegate count_favorites(user_id, opts \\ []), to: Library
  defdelegate add_favorite(user_id, attrs), to: Library
  defdelegate add_favorite(user_id, content_type, content_id, attrs \\ %{}), to: Library
  defdelegate remove_favorite(user_id, content_type, content_id), to: Library
  defdelegate toggle_favorite(user_id, content_type, content_id, attrs \\ %{}), to: Library

  # =============================================================================
  # Watch History (catalog_item_id via WatchProgress)
  # =============================================================================
  defdelegate list_watch_history(user_id, opts \\ []), to: Library
  defdelegate list_home_history(user_id, opts \\ []), to: Library
  defdelegate list_watch_history_for_analytics(user_id, opts \\ []), to: Library
  defdelegate count_watch_history_by_type(user_id, opts \\ []), to: Library

  defdelegate add_watch_history(user_id, content_type, content_id, attrs \\ %{}),
    to: Library

  defdelegate add_to_watch_history(user_id, attrs), to: Library

  defdelegate update_progress(user_id, content_type, content_id, progress, duration \\ nil),
    to: Library

  defdelegate update_watch_progress(user_id, content_type, content_id, current_time, duration),
    to: Library

  defdelegate update_watch_time(user_id, content_type, content_id, duration_seconds),
    to: Library

  defdelegate remove_from_watch_history(user_id, entry_id), to: Library
  defdelegate clear_watch_history(user_id), to: Library
  defdelegate get_watch_progress_map(user_id, content_type, content_ids), to: Library
  defdelegate get_series_progress_map(user_id, series_ids), to: Library

  # =============================================================================
  # Live Channels
  # =============================================================================
  defdelegate list_live_channels(provider_id, opts \\ []), to: CatalogBoundary
  defdelegate list_visible_live_channels(user_id, opts \\ []), to: CatalogBoundary
  defdelegate list_public_channels(opts \\ []), to: CatalogBoundary
  defdelegate list_public_catalog_channels(opts \\ []), to: CatalogBoundary
  defdelegate count_public_catalog_channels(opts \\ []), to: CatalogBoundary
  defdelegate count_live_channels(provider_id, opts \\ []), to: Channels, as: :count
  defdelegate get_live_channel!(id), to: Channels, as: :get!
  defdelegate get_live_channel(id), to: Channels, as: :get
  defdelegate get_live_channel_for_stream(id), to: PlaybackBoundary
  defdelegate get_user_live_channel(user_id, channel_id), to: Channels, as: :get_user_channel
  defdelegate get_playable_channel(user_id, channel_id), to: PlaybackBoundary
  defdelegate get_public_channel(channel_id), to: CatalogBoundary
  defdelegate get_live_channel_with_provider!(id), to: Channels, as: :get_with_provider!
  defdelegate search_channels(user_id, query, opts \\ []), to: Search
  defdelegate search_public_channels(query, opts \\ []), to: Search

  defdelegate channel_recommendation_category_refs(channel_ids), to: CatalogBoundary
  defdelegate list_channel_recommendation_candidates(user_id, opts \\ []), to: CatalogBoundary

  defdelegate live_channel_stream_url(channel, provider), to: PlaybackBoundary

  # =============================================================================
  # Movies (VOD)
  # =============================================================================
  defdelegate list_movies(provider_id, opts \\ []), to: CatalogBoundary
  defdelegate list_visible_movies(user_id, opts \\ []), to: CatalogBoundary
  defdelegate list_public_movies(opts \\ []), to: CatalogBoundary
  defdelegate list_public_catalog_movies(opts \\ []), to: CatalogBoundary
  defdelegate count_public_catalog_movies(opts \\ []), to: CatalogBoundary
  defdelegate count_movies(provider_id, opts \\ []), to: Movies, as: :count
  defdelegate get_movie!(id), to: CatalogBoundary
  defdelegate get_movie(id), to: CatalogBoundary
  defdelegate get_movie_for_stream(id), to: PlaybackBoundary
  defdelegate get_user_movie(user_id, movie_id), to: Movies
  defdelegate get_playable_movie(user_id, movie_id), to: PlaybackBoundary
  defdelegate get_public_movie(movie_id), to: CatalogBoundary
  defdelegate get_movie_with_provider!(id), to: CatalogBoundary
  defdelegate fetch_movie_info(movie), to: CatalogBoundary
  defdelegate search_movies(user_id, query, opts \\ []), to: Search
  defdelegate search_public_movies(query, opts \\ []), to: Search
  defdelegate get_movies_by_ids(ids), to: CatalogBoundary

  defdelegate list_visible_movies_by_ids(user_id, ids, opts \\ []), to: CatalogBoundary

  defdelegate list_public_movies_by_ids(ids, opts \\ []), to: CatalogBoundary
  defdelegate list_movie_genre_names(ids), to: CatalogBoundary

  defdelegate list_movie_variants(movie, user_id, opts \\ []), to: PlaybackBoundary

  # GIndex Movies
  defdelegate list_gindex_movies(opts \\ []), to: CatalogBoundary
  defdelegate count_gindex_movies, to: Movies, as: :count_gindex

  # Torrent Movies
  defdelegate upsert_torrent_movie(provider_id, attrs), to: CatalogBoundary
  defdelegate list_torrent_movies(provider_id, opts \\ []), to: CatalogBoundary
  defdelegate count_torrent_movies(provider_id, opts \\ []), to: CatalogBoundary
  defdelegate get_torrent_movie_for_playback(movie_id), to: CatalogBoundary

  # =============================================================================
  # Series
  # =============================================================================
  defdelegate list_series(provider_id, opts \\ []), to: CatalogBoundary
  defdelegate list_visible_series(user_id, opts \\ []), to: CatalogBoundary
  defdelegate list_public_series(opts \\ []), to: CatalogBoundary
  defdelegate list_public_catalog_series(opts \\ []), to: CatalogBoundary

  defdelegate count_public_catalog_series(opts \\ []), to: CatalogBoundary

  defdelegate count_series(provider_id, opts \\ []), to: SeriesOps, as: :count
  defdelegate get_series!(id), to: CatalogBoundary
  defdelegate get_series(id), to: SeriesOps, as: :get
  defdelegate get_playable_series(user_id, series_id), to: PlaybackBoundary
  defdelegate get_public_series(series_id), to: CatalogBoundary
  defdelegate get_series_with_seasons(id), to: SeriesOps, as: :get_with_seasons
  defdelegate get_series_with_seasons!(id), to: SeriesOps, as: :get_with_seasons!
  defdelegate get_series_with_sync!(id), to: CatalogBoundary
  defdelegate fetch_series_info(series), to: CatalogBoundary
  defdelegate search_series(user_id, query, opts \\ []), to: Search
  defdelegate search_public_series(query, opts \\ []), to: Search
  defdelegate get_series_by_ids(ids), to: CatalogBoundary

  defdelegate list_visible_series_by_ids(user_id, ids, opts \\ []), to: CatalogBoundary

  defdelegate list_public_series_by_ids(ids, opts \\ []), to: CatalogBoundary

  defdelegate list_series_variants(series, user_id, opts \\ []), to: PlaybackBoundary

  # GIndex Series
  defdelegate list_gindex_series(opts \\ []), to: CatalogBoundary
  defdelegate count_gindex_series, to: SeriesOps, as: :count_gindex
  defdelegate get_gindex_series_with_seasons(id), to: CatalogBoundary

  # GIndex Animes
  defdelegate list_gindex_animes(opts \\ []), to: CatalogBoundary
  defdelegate count_gindex_animes, to: SeriesOps
  defdelegate get_gindex_anime_with_seasons(id), to: CatalogBoundary

  defdelegate gindex_counts(), to: CatalogBoundary

  @doc """
  Persists normalized GIndex movie records without exposing IPTV schemas.
  """
  @spec upsert_gindex_movies(pos_integer(), [map()], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate upsert_gindex_movies(provider_id, movies, now), to: CatalogBoundary

  @doc """
  Persists one normalized GIndex series tree atomically.
  """
  @spec upsert_gindex_series(pos_integer(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate upsert_gindex_series(provider_id, content, now), to: CatalogBoundary

  @doc "Returns GIndex paths already represented in one provider's catalog."
  @spec gindex_known_paths(pos_integer(), :movies | :series | :animes) ::
          MapSet.t(String.t())
  defdelegate gindex_known_paths(provider_id, kind), to: ProviderBoundary

  # =============================================================================
  # Episodes
  # =============================================================================
  defdelegate get_episode!(id), to: SeriesOps
  defdelegate get_episode(id), to: SeriesOps
  defdelegate get_episode_for_stream(id), to: PlaybackBoundary
  defdelegate get_user_episode(user_id, episode_id), to: SeriesOps
  defdelegate get_playable_episode(user_id, episode_id), to: PlaybackBoundary
  defdelegate get_public_episode(episode_id), to: CatalogBoundary
  defdelegate get_episode_with_context!(id), to: CatalogBoundary
  defdelegate list_season_episodes(season_id), to: CatalogBoundary
  defdelegate fetch_episode_info(episode), to: CatalogBoundary
  defdelegate get_next_episode(episode_id), to: CatalogBoundary

  # GIndex media-track probe boundary. Callers outside IPTV receive a small
  # projection instead of depending on Movie/Episode schemas or Repo directly.
  @spec get_media_track_source(:movie | :episode, pos_integer()) ::
          {:ok,
           %{
             id: pos_integer(),
             gindex_path: String.t() | nil,
             track_metadata: map() | nil
           }}
          | {:error, :not_found | :unsupported_type}
  defdelegate get_media_track_source(type, id), to: CatalogBoundary

  @spec put_media_track_metadata(:movie | :episode, pos_integer(), term()) ::
          :ok | {:error, :invalid_metadata | :not_found | :unsupported_type}
  defdelegate put_media_track_metadata(type, id, metadata), to: CatalogBoundary

  @type gindex_stream_source :: %{
          base_url: String.t(),
          path: String.t(),
          cached_url: String.t() | nil,
          cached_until: DateTime.t() | nil
        }
  @type gindex_stream_source_error ::
          :movie_not_found
          | :episode_not_found
          | :not_gindex_movie
          | :not_gindex_episode
          | :unsupported_type

  @spec get_gindex_stream_source(:movie | :episode, pos_integer()) ::
          {:ok, gindex_stream_source()} | {:error, gindex_stream_source_error()}
  defdelegate get_gindex_stream_source(type, id), to: PlaybackBoundary

  @spec put_gindex_stream_cache(:movie | :episode, pos_integer(), String.t(), DateTime.t()) ::
          :ok | {:error, :invalid_cache | :not_found | :unsupported_type}
  defdelegate put_gindex_stream_cache(type, id, url, expires_at), to: PlaybackBoundary

  # =============================================================================
  # Providers — compatibility delegates

  defdelegate list_providers(user_id), to: ProviderBoundary
  defdelegate list_providers(user_id, opts), to: ProviderBoundary
  defdelegate list_visible_providers(user_id \\ nil), to: ProviderBoundary
  defdelegate list_public_providers(), to: ProviderBoundary
  defdelegate list_stale_sync_candidates(threshold), to: ProviderBoundary
  defdelegate get_provider!(id), to: ProviderBoundary
  defdelegate get_provider(id), to: ProviderBoundary
  defdelegate preload_provider_drives(provider), to: ProviderBoundary

  @type gindex_sync_drive :: ProviderBoundary.gindex_sync_drive()
  @type gindex_sync_source :: ProviderBoundary.gindex_sync_source()

  @spec gindex_sync_source(term()) ::
          {:ok, gindex_sync_source()} | {:error, :not_gindex_provider}
  defdelegate gindex_sync_source(provider), to: ProviderBoundary

  @spec update_gindex_sync(pos_integer(), map()) ::
          {:ok, Provider.t()}
          | {:error, :gindex_provider_not_found | {:invalid_gindex_sync_fields, term()}}
          | {:error, Ecto.Changeset.t()}
  defdelegate update_gindex_sync(provider_id, attrs), to: ProviderBoundary

  @spec refresh_gindex_counts(pos_integer(), map()) ::
          {:ok, Provider.t()} | {:error, :gindex_provider_not_found | Ecto.Changeset.t()}
  defdelegate refresh_gindex_counts(provider_id, attrs \\ %{}), to: ProviderBoundary

  @type torrent_sync_source :: ProviderBoundary.torrent_sync_source()

  @spec torrent_sync_source(term()) ::
          {:ok, torrent_sync_source()} | {:error, :not_torrent_provider}
  defdelegate torrent_sync_source(provider), to: ProviderBoundary

  @spec update_torrent_sync(pos_integer(), map()) ::
          {:ok, Provider.t()}
          | {:error, :torrent_provider_not_found | {:invalid_torrent_sync_fields, term()}}
          | {:error, Ecto.Changeset.t()}
  defdelegate update_torrent_sync(provider_id, attrs), to: ProviderBoundary

  defdelegate get_user_provider(user_id, provider_id), to: ProviderBoundary
  defdelegate get_public_provider(provider_id), to: ProviderBoundary
  defdelegate get_global_provider(), to: ProviderBoundary
  defdelegate list_personal_xtream_providers(), to: ProviderBoundary
  defdelegate get_playable_provider(user_id, provider_id), to: ProviderBoundary
  defdelegate create_provider(attrs), to: ProviderBoundary
  defdelegate create_provider(user_id, attrs), to: ProviderBoundary
  defdelegate update_provider(provider, attrs), to: ProviderBoundary
  defdelegate update_user_provider(user_id, provider, attrs), to: ProviderBoundary
  defdelegate delete_provider(provider), to: ProviderBoundary
  defdelegate change_provider(provider, attrs \\ %{}), to: ProviderBoundary
  defdelegate new_provider(), to: ProviderBoundary
  defdelegate new_provider_changeset(attrs \\ %{}), to: ProviderBoundary
  defdelegate test_connection(url, username, password), to: ProviderBoundary
  defdelegate sync_provider(provider, opts \\ []), to: ProviderBoundary
  defdelegate async_sync_provider(provider), to: ProviderBoundary

  @type provider_sync_section :: ProviderBoundary.provider_sync_section()

  @spec sync_provider_section(Provider.t(), provider_sync_section()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate sync_provider_section(provider, section), to: ProviderBoundary

  defdelegate global_provider_enabled?(), to: ProviderBoundary
  defdelegate ensure_global_provider(owner \\ nil), to: ProviderBoundary
  defdelegate gindex_provider_enabled?(), to: ProviderBoundary
  defdelegate ensure_gindex_provider(), to: ProviderBoundary
  defdelegate torrent_provider_enabled?(), to: ProviderBoundary
  defdelegate ensure_torrent_provider(), to: ProviderBoundary
  defdelegate get_torrent_provider(), to: ProviderBoundary
  defdelegate get_torrent_provider_ref(), to: ProviderBoundary
  defdelegate provider_health_summary(), to: ProviderBoundary
  defdelegate provider_health_summary(reports), to: ProviderBoundary
  defdelegate list_provider_health_reports(opts \\ []), to: ProviderBoundary
  defdelegate cached_provider_health_summary(), to: ProviderBoundary

  defdelegate provider_stream_url_chain(provider, original_url), to: PlaybackBoundary

  # =============================================================================
  # Catalog (Public Content)
  # =============================================================================
  defdelegate get_featured_content(opts \\ []), to: CatalogBoundary
  defdelegate get_public_stats(opts \\ []), to: CatalogBoundary

  defdelegate list_search_documents(kind, provider_id \\ nil, opts \\ []), to: Search

  defdelegate list_genres_for(kind), to: Catalog

  defdelegate list_public_movies_by_genre(genre, opts \\ []),
    to: Catalog,
    as: :list_movies_by_genre

  defdelegate list_recently_added(opts \\ []), to: Catalog
  defdelegate list_trending_movies(opts \\ []), to: CatalogBoundary
  defdelegate list_trending_series(opts \\ []), to: Catalog
  defdelegate list_new_releases(opts \\ []), to: CatalogBoundary
  defdelegate list_top_10_movies(opts \\ []), to: CatalogBoundary
  defdelegate list_top_10_series(opts \\ []), to: CatalogBoundary
  defdelegate list_recent_movies(opts \\ []), to: Catalog
  defdelegate list_recent_series(opts \\ []), to: Catalog
  defdelegate list_trending(type, opts \\ []), to: CatalogBoundary
  defdelegate list_recent(type, opts \\ []), to: CatalogBoundary
  defdelegate list_top_rated(type, opts \\ []), to: CatalogBoundary
  defdelegate list_categories(provider_id, type \\ nil), to: CatalogBoundary
  defdelegate list_public_categories(opts \\ []), to: CatalogBoundary
  defdelegate get_category!(id), to: Catalog
  defdelegate get_catalog_item_with_content(catalog_item_id), to: CatalogBoundary

  # =============================================================================
  # Content assets
  # =============================================================================
  defdelegate backdrop_urls(content), to: CatalogBoundary
  defdelegate image_urls(content), to: CatalogBoundary
  defdelegate has_images?(content), to: CatalogBoundary

  @type tmdb_kind :: :movie | :series

  @spec search_tmdb(tmdb_kind(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate search_tmdb(kind, query, opts \\ []), to: Search

  defdelegate catalog_item_content(catalog_item), to: CatalogBoundary
  defdelegate catalog_item_content_name(catalog_item), to: CatalogBoundary
  defdelegate catalog_item_content_icon(catalog_item), to: CatalogBoundary
  defdelegate resolve_catalog_item_id(content_type, content_id), to: CatalogBoundary

  # =============================================================================
  # EPG (Electronic Program Guide)
  # =============================================================================
  defdelegate get_now_and_next(provider_id, epg_channel_id), to: Guide
  defdelegate get_current_programs_batch(provider_id, epg_channel_ids), to: Guide
  defdelegate current_programs_for_channels(provider_id, channel_ids), to: Guide

  defdelegate programs_window_for_channels(provider_id, channel_ids, starts_at, ends_at),
    to: Guide

  defdelegate epg_program_progress(program), to: Guide

  defdelegate enrich_channels_with_epg(channels, provider_id), to: Guide
  defdelegate sync_channel_epg(provider, stream_id, epg_channel_id), to: Guide
  defdelegate sync_channels_epg(provider, channels), to: Guide
  defdelegate ensure_epg_available(provider, channels), to: Guide
  defdelegate sync_all_epg(provider), to: Guide

  @doc """
  Enqueues a background job to sync EPG for all channels of a provider.
  Uses Oban for persistent job processing.
  """
  defdelegate async_sync_epg(provider), to: Guide

  defdelegate sync_series_details(series), to: CatalogBoundary

  defdelegate cleanup_orphaned_user_data(provider_id \\ nil, opts \\ []),
    to: Library

  # =============================================================================
  # Stream delivery
  # =============================================================================
  @type stream_error_code :: StreamErrors.code()

  defdelegate halt_stream_error(conn, code, opts \\ []), to: PlaybackBoundary
  defdelegate stream_error_code_from_reason(reason), to: PlaybackBoundary
  defdelegate resolve_stream_url(url, opts \\ []), to: PlaybackBoundary

  @doc "Resolves a stream URL using the source-proxy credential-exchange policy."
  defdelegate resolve_stream_url_for_proxy(url, opts \\ []), to: PlaybackBoundary

  @doc "Prewarms without fetching a single-use token target."
  defdelegate prewarm_stream_url(url, opts \\ []), to: PlaybackBoundary

  defdelegate pipe_stream(conn, url, opts \\ []), to: PlaybackBoundary
  defdelegate pipe_live_stream(conn, url, opts \\ []), to: PlaybackBoundary

  @doc """
  Streams VOD through the block multiplexer, so concurrent viewers of one
  title share upstream connections instead of each holding their own.

  Falls back to the direct proxy when the multiplexer is disabled or cannot
  serve the request, which keeps playback working against upstreams that
  ignore `Range`.
  """
  @spec pipe_vod_stream(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  defdelegate pipe_vod_stream(conn, url, opts \\ []), to: PlaybackBoundary

  defdelegate head_stream(conn, url, opts \\ []), to: PlaybackBoundary
  defdelegate sort_stream_sources(sources, opts \\ []), to: PlaybackBoundary
end
