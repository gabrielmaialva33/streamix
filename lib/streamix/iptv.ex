defmodule Streamix.Iptv do
  @moduledoc """
  IPTV context — facade for the catalog, sync, streaming, engagement
  and provider subsystems.

  ## Public API map

  Roughly grouped so newcomers can find where to call into:

  * **Browse / catalog** — `list_movies/2`, `list_series/2`, `list_live_channels/2`,
    `list_public_*`, `list_new_releases/1`, `list_trending_movies/1`, `search/2`,
    `get_movie/1`, `get_series/1`, `get_episode/1`, `get_live_channel/1`,
    `get_featured_content/1`, `get_public_stats/1`. Backed by `Streamix.Iptv.Catalog`
    plus the specialised `Movies`/`SeriesOps`/`Channels` modules.

  * **User data (favorites & history)** — `list_favorites/2`, `add_favorite/3`,
    `remove_favorite/3`, `toggle_favorite/4`, `favorite?/3`,
    `list_watch_history/2`, `add_watch_history/4`, `update_watch_progress/5`,
    `clear_watch_history/1`. Backed by `Streamix.Iptv.Favorites` and
    `Streamix.Iptv.History`.

  * **Providers** — `create_provider/2`, `update_provider/2`, `get_provider/1`,
    `sync_provider/2`, `async_sync_epg/1`, `list_providers/1`. Backed by
    `Streamix.Iptv.Providers`.

  * **EPG** — `get_now_and_next/2`, `sync_channel_epg/3`, `sync_channels_epg/2`.
    Backed by `Streamix.Iptv.Epg`.

  * **GIndex** — `gindex_counts/0`. Internals live under `Streamix.Gindex.*`.

  Sub-modules under `Streamix.Iptv.Streaming.*`, `Streamix.Iptv.Sync.*` and
  `Streamix.Torrent.*` are internal — controllers and LiveViews should
  call back into this facade rather than reach into the sub-modules directly.
  """

  require Logger

  alias Streamix.Cache

  alias Streamix.Iptv.{
    Assets,
    Catalog,
    CatalogItem,
    Channels,
    Content.GindexIngest,
    Content.GindexInventory,
    Content.GindexStream,
    Content.TorrentMovies,
    Content.TrackMetadata,
    ContentRef,
    Epg,
    EpgProgram,
    EpgSync,
    GIndexProvider,
    GlobalProvider,
    LiveChannel,
    Movies,
    Provider,
    Providers,
    SearchDocuments,
    SeriesOps,
    Sync,
    TmdbClient
  }

  alias Streamix.Workers.UpdateUserProfileWorker

  alias Streamix.Iptv.Streaming.{
    FailoverPolicy,
    LiveProxy,
    RedirectResolver,
    SourceSelector,
    StreamErrors,
    VodProxy
  }

  alias Streamix.Iptv.{
    Favorites,
    History,
    ProviderHealth,
    ProviderHealthMonitor,
    TorrentProvider
  }

  # =============================================================================
  # Favorites (catalog_item_id)
  # =============================================================================
  defdelegate list_favorites(user_id, opts \\ []), to: Favorites, as: :list
  defdelegate list_home_favorites(user_id, opts \\ []), to: Favorites, as: :list_home
  defdelegate favorite?(user_id, content_type, content_id), to: Favorites
  defdelegate count_favorites_by_type(user_id, opts \\ []), to: Favorites, as: :count_by_type

  defdelegate list_favorite_ids(user_id, content_type, content_ids \\ nil),
    to: Favorites,
    as: :list_ids

  defdelegate count_favorites(user_id, opts \\ []), to: Favorites, as: :count
  defdelegate add_favorite(user_id, attrs), to: Favorites, as: :add

  defdelegate add_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :add

  defdelegate remove_favorite(user_id, content_type, content_id), to: Favorites, as: :remove

  defdelegate toggle_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :toggle

  # =============================================================================
  # Watch History (catalog_item_id via WatchProgress)
  # =============================================================================
  defdelegate list_watch_history(user_id, opts \\ []), to: History, as: :list
  defdelegate list_home_history(user_id, opts \\ []), to: History, as: :list_home

  defdelegate list_watch_history_for_analytics(user_id, opts \\ []),
    to: History,
    as: :list_for_analytics

  defdelegate count_watch_history_by_type(user_id, opts \\ []),
    to: History,
    as: :count_by_type

  def add_watch_history(user_id, content_type, content_id, attrs \\ %{}) do
    user_id
    |> History.add(content_type, content_id, attrs)
    |> after_history_write(user_id)
  end

  def add_to_watch_history(user_id, attrs) do
    user_id
    |> History.add(attrs)
    |> after_history_write(user_id)
  end

  def update_progress(user_id, content_type, content_id, progress, duration \\ nil) do
    user_id
    |> History.update_progress(content_type, content_id, progress, duration)
    |> after_history_write(user_id)
  end

  def update_watch_progress(user_id, content_type, content_id, current_time, duration) do
    user_id
    |> History.update_watch_progress(content_type, content_id, current_time, duration)
    |> after_history_write(user_id)
  end

  def update_watch_time(user_id, content_type, content_id, duration_seconds) do
    user_id
    |> History.update_watch_time(content_type, content_id, duration_seconds)
    |> after_history_write(user_id)
  end

  def remove_from_watch_history(user_id, entry_id) do
    result = History.remove(user_id, entry_id)
    if match?({count, _} when count > 0, result), do: queue_personalization_refresh(user_id)
    result
  end

  def clear_watch_history(user_id) do
    result = History.clear(user_id)
    if match?({:ok, count} when count > 0, result), do: queue_personalization_refresh(user_id)
    result
  end

  defp after_history_write({:ok, _entry} = result, user_id) do
    queue_personalization_refresh(user_id)
    result
  end

  defp after_history_write(result, _user_id), do: result

  defp queue_personalization_refresh(user_id) do
    Cache.fetch_local({__MODULE__, :personalization_refresh, user_id}, :timer.minutes(1), fn ->
      Cache.invalidate_personalization(user_id)

      case UpdateUserProfileWorker.schedule(user_id) do
        {:ok, _job} ->
          :scheduled

        {:error, reason} ->
          Logger.warning("Failed to schedule user profile refresh",
            user_id: user_id,
            reason: inspect(reason)
          )

          :schedule_failed
      end
    end)
  end

  defdelegate get_watch_progress_map(user_id, content_type, content_ids),
    to: History,
    as: :get_progress_map

  defdelegate get_series_progress_map(user_id, series_ids), to: History

  # =============================================================================
  # Live Channels
  # =============================================================================
  defdelegate list_live_channels(provider_id, opts \\ []), to: Channels, as: :list
  defdelegate list_visible_live_channels(user_id, opts \\ []), to: Channels, as: :list_visible
  defdelegate list_public_channels(opts \\ []), to: Channels, as: :list_public
  defdelegate list_public_catalog_channels(opts \\ []), to: Channels, as: :list_public_catalog
  defdelegate count_public_catalog_channels(opts \\ []), to: Channels, as: :count_public_catalog
  defdelegate count_live_channels(provider_id, opts \\ []), to: Channels, as: :count
  defdelegate get_live_channel!(id), to: Channels, as: :get!
  defdelegate get_live_channel(id), to: Channels, as: :get
  defdelegate get_live_channel_for_stream(id), to: Channels, as: :get_for_stream
  defdelegate get_user_live_channel(user_id, channel_id), to: Channels, as: :get_user_channel
  defdelegate get_playable_channel(user_id, channel_id), to: Channels, as: :get_playable
  defdelegate get_public_channel(channel_id), to: Channels, as: :get_public
  defdelegate get_live_channel_with_provider!(id), to: Channels, as: :get_with_provider!
  defdelegate search_channels(user_id, query, opts \\ []), to: Channels, as: :search
  defdelegate search_public_channels(query, opts \\ []), to: Channels, as: :search_public

  defdelegate channel_recommendation_category_refs(channel_ids),
    to: Channels,
    as: :recommendation_category_refs

  defdelegate list_channel_recommendation_candidates(user_id, opts \\ []),
    to: Channels,
    as: :list_recommendation_candidates

  defdelegate live_channel_stream_url(channel, provider), to: LiveChannel, as: :stream_url

  # =============================================================================
  # Movies (VOD)
  # =============================================================================
  defdelegate list_movies(provider_id, opts \\ []), to: Movies, as: :list
  defdelegate list_visible_movies(user_id, opts \\ []), to: Movies, as: :list_visible
  defdelegate list_public_movies(opts \\ []), to: Movies, as: :list_public
  defdelegate list_public_catalog_movies(opts \\ []), to: Movies, as: :list_public_catalog
  defdelegate count_public_catalog_movies(opts \\ []), to: Movies, as: :count_public_catalog
  defdelegate count_movies(provider_id, opts \\ []), to: Movies, as: :count
  defdelegate get_movie!(id), to: Movies, as: :get!
  defdelegate get_movie(id), to: Movies, as: :get
  defdelegate get_movie_for_stream(id), to: Movies, as: :get_for_stream
  defdelegate get_user_movie(user_id, movie_id), to: Movies
  defdelegate get_playable_movie(user_id, movie_id), to: Movies, as: :get_playable
  defdelegate get_public_movie(movie_id), to: Movies, as: :get_public
  defdelegate get_movie_with_provider!(id), to: Movies, as: :get_with_provider!
  defdelegate fetch_movie_info(movie), to: Movies, as: :fetch_info
  defdelegate search_movies(user_id, query, opts \\ []), to: Movies, as: :search
  defdelegate search_public_movies(query, opts \\ []), to: Movies, as: :search_public
  defdelegate get_movies_by_ids(ids), to: Movies, as: :get_by_ids

  defdelegate list_visible_movies_by_ids(user_id, ids, opts \\ []),
    to: Movies,
    as: :list_visible_by_ids

  defdelegate list_public_movies_by_ids(ids, opts \\ []), to: Movies, as: :list_public_by_ids
  defdelegate list_movie_genre_names(ids), to: Movies, as: :list_genre_names_for_ids

  defdelegate list_movie_variants(movie, user_id, opts \\ []), to: Movies, as: :list_variants

  # GIndex Movies
  defdelegate list_gindex_movies(opts \\ []), to: Movies, as: :list_gindex
  defdelegate count_gindex_movies, to: Movies, as: :count_gindex

  # Torrent Movies
  defdelegate upsert_torrent_movie(provider_id, attrs), to: TorrentMovies, as: :upsert
  defdelegate list_torrent_movies(provider_id, opts \\ []), to: TorrentMovies, as: :list
  defdelegate count_torrent_movies(provider_id, opts \\ []), to: TorrentMovies, as: :count

  defdelegate get_torrent_movie_for_playback(movie_id),
    to: TorrentMovies,
    as: :get_for_playback

  # =============================================================================
  # Series
  # =============================================================================
  defdelegate list_series(provider_id, opts \\ []), to: SeriesOps, as: :list
  defdelegate list_visible_series(user_id, opts \\ []), to: SeriesOps, as: :list_visible
  defdelegate list_public_series(opts \\ []), to: SeriesOps, as: :list_public
  defdelegate list_public_catalog_series(opts \\ []), to: SeriesOps, as: :list_public_catalog

  defdelegate count_public_catalog_series(opts \\ []),
    to: SeriesOps,
    as: :count_public_catalog

  defdelegate count_series(provider_id, opts \\ []), to: SeriesOps, as: :count
  defdelegate get_series!(id), to: SeriesOps, as: :get!
  defdelegate get_series(id), to: SeriesOps, as: :get
  defdelegate get_playable_series(user_id, series_id), to: SeriesOps, as: :get_playable
  defdelegate get_public_series(series_id), to: SeriesOps, as: :get_public
  defdelegate get_series_with_seasons(id), to: SeriesOps, as: :get_with_seasons
  defdelegate get_series_with_seasons!(id), to: SeriesOps, as: :get_with_seasons!
  defdelegate get_series_with_sync!(id), to: SeriesOps, as: :get_with_sync!
  defdelegate fetch_series_info(series), to: SeriesOps, as: :fetch_info
  defdelegate search_series(user_id, query, opts \\ []), to: SeriesOps, as: :search
  defdelegate search_public_series(query, opts \\ []), to: SeriesOps, as: :search_public
  defdelegate get_series_by_ids(ids), to: SeriesOps, as: :get_by_ids

  defdelegate list_visible_series_by_ids(user_id, ids, opts \\ []),
    to: SeriesOps,
    as: :list_visible_by_ids

  defdelegate list_public_series_by_ids(ids, opts \\ []),
    to: SeriesOps,
    as: :list_public_by_ids

  defdelegate list_series_variants(series, user_id, opts \\ []), to: SeriesOps, as: :list_variants

  # GIndex Series
  defdelegate list_gindex_series(opts \\ []), to: SeriesOps, as: :list_gindex
  defdelegate count_gindex_series, to: SeriesOps, as: :count_gindex
  defdelegate get_gindex_series_with_seasons(id), to: SeriesOps, as: :get_gindex_with_seasons

  # GIndex Animes
  defdelegate list_gindex_animes(opts \\ []), to: SeriesOps
  defdelegate count_gindex_animes, to: SeriesOps
  defdelegate get_gindex_anime_with_seasons(id), to: SeriesOps

  @doc """
  Returns all GIndex content counts in a single call for efficient tab rendering.
  """
  @spec gindex_counts() :: %{movies: integer(), series: integer(), animes: integer()}
  def gindex_counts do
    %{
      movies: Movies.count_gindex(),
      series: SeriesOps.count_gindex(),
      animes: SeriesOps.count_gindex_animes()
    }
  end

  @doc """
  Persists normalized GIndex movie records without exposing IPTV schemas.
  """
  @spec upsert_gindex_movies(pos_integer(), [map()], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate upsert_gindex_movies(provider_id, movies, now),
    to: GindexIngest,
    as: :upsert_movies

  @doc """
  Persists one normalized GIndex series tree atomically.
  """
  @spec upsert_gindex_series(pos_integer(), map(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate upsert_gindex_series(provider_id, content, now),
    to: GindexIngest,
    as: :upsert_series

  @doc "Returns GIndex paths already represented in one provider's catalog."
  @spec gindex_known_paths(pos_integer(), :movies | :series | :animes) ::
          MapSet.t(String.t())
  defdelegate gindex_known_paths(provider_id, kind), to: GindexInventory, as: :known_paths

  # =============================================================================
  # Episodes
  # =============================================================================
  defdelegate get_episode!(id), to: SeriesOps
  defdelegate get_episode(id), to: SeriesOps
  defdelegate get_episode_for_stream(id), to: SeriesOps
  defdelegate get_user_episode(user_id, episode_id), to: SeriesOps
  defdelegate get_playable_episode(user_id, episode_id), to: SeriesOps
  defdelegate get_public_episode(episode_id), to: SeriesOps
  defdelegate get_episode_with_context!(id), to: SeriesOps
  defdelegate list_season_episodes(season_id), to: SeriesOps
  defdelegate fetch_episode_info(episode), to: SeriesOps
  defdelegate get_next_episode(episode_id), to: SeriesOps

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
  defdelegate get_media_track_source(type, id), to: TrackMetadata, as: :get_source

  @spec put_media_track_metadata(:movie | :episode, pos_integer(), term()) ::
          :ok | {:error, :invalid_metadata | :not_found | :unsupported_type}
  defdelegate put_media_track_metadata(type, id, metadata), to: TrackMetadata, as: :put

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
  defdelegate get_gindex_stream_source(type, id), to: GindexStream, as: :get_source

  @spec put_gindex_stream_cache(:movie | :episode, pos_integer(), String.t(), DateTime.t()) ::
          :ok | {:error, :invalid_cache | :not_found | :unsupported_type}
  defdelegate put_gindex_stream_cache(type, id, url, expires_at),
    to: GindexStream,
    as: :put_cache

  # =============================================================================
  # Providers
  # =============================================================================
  defdelegate list_providers(user_id), to: Providers, as: :list
  defdelegate list_providers(user_id, opts), to: Providers, as: :list
  defdelegate list_visible_providers(user_id \\ nil), to: Providers, as: :list_visible
  defdelegate list_public_providers(), to: Providers, as: :list_public
  defdelegate list_stale_sync_candidates(threshold), to: Providers
  defdelegate get_provider!(id), to: Providers, as: :get!
  defdelegate get_provider(id), to: Providers, as: :get
  defdelegate preload_provider_drives(provider), to: Providers, as: :preload_drives

  @type gindex_sync_drive :: %{kind: String.t(), metadata: map()}
  @type gindex_sync_source :: %{
          provider_id: pos_integer(),
          name: String.t(),
          base_url: String.t(),
          drives: [gindex_sync_drive()]
        }

  @spec gindex_sync_source(term()) ::
          {:ok, gindex_sync_source()} | {:error, :not_gindex_provider}
  defdelegate gindex_sync_source(provider), to: Providers

  @spec update_gindex_sync(pos_integer(), map()) ::
          :ok
          | {:error,
             :gindex_provider_not_found
             | {:invalid_gindex_sync_fields, [term()]}
             | Ecto.Changeset.t()}
  defdelegate update_gindex_sync(provider_id, attrs), to: Providers

  @spec refresh_gindex_counts(pos_integer(), map()) ::
          {:ok, Provider.t()} | {:error, :gindex_provider_not_found | Ecto.Changeset.t()}
  defdelegate refresh_gindex_counts(provider_id, attrs \\ %{}), to: Providers

  @type torrent_sync_source :: %{
          provider_id: pos_integer(),
          name: String.t()
        }

  @spec torrent_sync_source(term()) ::
          {:ok, torrent_sync_source()} | {:error, :not_torrent_provider}
  defdelegate torrent_sync_source(provider), to: Providers

  @spec update_torrent_sync(pos_integer(), map()) ::
          :ok
          | {:error,
             :torrent_provider_not_found
             | {:invalid_torrent_sync_fields, [term()]}
             | Ecto.Changeset.t()}
  defdelegate update_torrent_sync(provider_id, attrs), to: Providers

  defdelegate get_user_provider(user_id, provider_id), to: Providers
  defdelegate get_public_provider(provider_id), to: Providers, as: :get_public
  defdelegate get_global_provider(), to: Providers, as: :get_global
  defdelegate list_personal_xtream_providers(), to: Providers, as: :list_personal_xtream
  defdelegate get_playable_provider(user_id, provider_id), to: Providers, as: :get_playable
  defdelegate create_provider(attrs), to: Providers, as: :create
  defdelegate create_provider(user_id, attrs), to: Providers, as: :create_for_user
  defdelegate update_provider(provider, attrs), to: Providers, as: :update
  defdelegate update_user_provider(user_id, provider, attrs), to: Providers, as: :update_for_user
  defdelegate delete_provider(provider), to: Providers, as: :delete
  defdelegate change_provider(provider, attrs \\ %{}), to: Providers, as: :change

  def new_provider, do: %Provider{}
  def new_provider_changeset(attrs \\ %{}), do: Providers.change(%Provider{}, attrs)

  defdelegate test_connection(url, username, password), to: Providers
  defdelegate sync_provider(provider, opts \\ []), to: Providers, as: :sync
  defdelegate async_sync_provider(provider), to: Providers, as: :async_sync

  @type provider_sync_section :: Sync.section()

  @spec sync_provider_section(Provider.t(), provider_sync_section()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate sync_provider_section(provider, section), to: Sync, as: :sync_section

  defdelegate global_provider_enabled?(), to: GlobalProvider, as: :enabled?

  defdelegate ensure_global_provider(owner \\ nil),
    to: GlobalProvider,
    as: :ensure_exists!

  defdelegate gindex_provider_enabled?(), to: GIndexProvider, as: :enabled?
  defdelegate ensure_gindex_provider(), to: GIndexProvider, as: :ensure_exists!
  defdelegate torrent_provider_enabled?(), to: TorrentProvider, as: :enabled?
  defdelegate ensure_torrent_provider(), to: TorrentProvider, as: :ensure_exists!
  defdelegate get_torrent_provider(), to: TorrentProvider, as: :get
  defdelegate get_torrent_provider_ref(), to: TorrentProvider, as: :get_ref
  defdelegate provider_health_summary(), to: ProviderHealth, as: :overall_status
  defdelegate provider_health_summary(reports), to: ProviderHealth, as: :overall_status
  defdelegate list_provider_health_reports(opts \\ []), to: ProviderHealth, as: :list_reports
  defdelegate cached_provider_health_summary(), to: ProviderHealthMonitor, as: :get

  @doc """
  Builds the failover URL chain for a provider without exposing provider internals.
  """
  def provider_stream_url_chain(provider, original_url) do
    FailoverPolicy.build_url_chain(original_url, Provider.url_chain(provider))
  end

  # =============================================================================
  # Catalog (Public Content)
  # =============================================================================
  defdelegate get_featured_content(opts \\ []), to: Catalog
  defdelegate get_public_stats(opts \\ []), to: Catalog

  defdelegate list_search_documents(kind, provider_id \\ nil, opts \\ []),
    to: SearchDocuments,
    as: :list

  defdelegate list_genres_for(kind), to: Catalog

  defdelegate list_public_movies_by_genre(genre, opts \\ []),
    to: Catalog,
    as: :list_movies_by_genre

  defdelegate list_recently_added(opts \\ []), to: Catalog
  defdelegate list_trending_movies(opts \\ []), to: Catalog
  defdelegate list_trending_series(opts \\ []), to: Catalog
  defdelegate list_new_releases(opts \\ []), to: Catalog
  defdelegate list_top_10_movies(opts \\ []), to: Catalog
  defdelegate list_top_10_series(opts \\ []), to: Catalog
  defdelegate list_recent_movies(opts \\ []), to: Catalog
  defdelegate list_recent_series(opts \\ []), to: Catalog
  defdelegate list_trending(type, opts \\ []), to: Catalog
  defdelegate list_recent(type, opts \\ []), to: Catalog
  defdelegate list_top_rated(type, opts \\ []), to: Catalog
  defdelegate list_categories(provider_id, type \\ nil), to: Catalog
  defdelegate list_public_categories(opts \\ []), to: Catalog
  defdelegate get_category!(id), to: Catalog
  defdelegate get_catalog_item_with_content(catalog_item_id), to: Catalog

  # =============================================================================
  # Content assets
  # =============================================================================
  defdelegate backdrop_urls(content), to: Assets
  defdelegate image_urls(content), to: Assets
  defdelegate has_images?(content), to: Assets

  @type tmdb_kind :: :movie | :series

  @spec search_tmdb(tmdb_kind(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def search_tmdb(kind, query, opts \\ [])

  def search_tmdb(:movie, query, opts), do: TmdbClient.search_movie(query, opts)
  def search_tmdb(:series, query, opts), do: TmdbClient.search_series(query, opts)

  defdelegate catalog_item_content(catalog_item), to: CatalogItem, as: :content
  defdelegate catalog_item_content_name(catalog_item), to: CatalogItem, as: :content_name
  defdelegate catalog_item_content_icon(catalog_item), to: CatalogItem, as: :content_icon

  defdelegate resolve_catalog_item_id(content_type, content_id),
    to: ContentRef,
    as: :resolve_catalog_item_id

  # =============================================================================
  # EPG (Electronic Program Guide)
  # =============================================================================
  defdelegate get_now_and_next(provider_id, epg_channel_id), to: Epg
  defdelegate get_current_programs_batch(provider_id, epg_channel_ids), to: Epg
  defdelegate current_programs_for_channels(provider_id, channel_ids), to: Epg

  defdelegate programs_window_for_channels(provider_id, channel_ids, starts_at, ends_at),
    to: Epg

  defdelegate epg_program_progress(program), to: EpgProgram, as: :progress

  defdelegate enrich_channels_with_epg(channels, provider_id), to: Epg
  defdelegate sync_channel_epg(provider, stream_id, epg_channel_id), to: Epg, as: :sync_channel
  defdelegate sync_channels_epg(provider, channels), to: Epg, as: :sync_channels
  defdelegate ensure_epg_available(provider, channels), to: Epg
  defdelegate sync_all_epg(provider), to: EpgSync

  @doc """
  Enqueues a background job to sync EPG for all channels of a provider.
  Uses Oban for persistent job processing.
  """
  def async_sync_epg(provider) do
    alias Streamix.Workers.SyncEpgWorker
    SyncEpgWorker.enqueue(provider)
  end

  defdelegate sync_series_details(series), to: Sync

  defdelegate cleanup_orphaned_user_data(provider_id \\ nil, opts \\ []),
    to: Sync

  # =============================================================================
  # Stream delivery
  # =============================================================================
  @type stream_error_code :: StreamErrors.code()

  defdelegate halt_stream_error(conn, code, opts \\ []), to: StreamErrors, as: :halt
  defdelegate stream_error_code_from_reason(reason), to: StreamErrors, as: :code_from_reason
  defdelegate resolve_stream_url(url, opts \\ []), to: RedirectResolver, as: :resolve
  defdelegate prewarm_stream_url(url, opts \\ []), to: RedirectResolver, as: :prewarm_async
  defdelegate pipe_stream(conn, url, opts \\ []), to: VodProxy, as: :pipe
  defdelegate pipe_live_stream(conn, url, opts \\ []), to: LiveProxy, as: :pipe
  defdelegate head_stream(conn, url, opts \\ []), to: VodProxy, as: :head
  defdelegate sort_stream_sources(sources, opts \\ []), to: SourceSelector, as: :sort
end
