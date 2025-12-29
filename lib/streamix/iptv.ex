defmodule Streamix.Iptv do
  @moduledoc """
  The IPTV context - manages providers, live channels, movies, series, favorites, and watch history.
  """

  alias Streamix.Iptv.{
    Catalog,
    Channels,
    Epg,
    Favorites,
    History,
    Movies,
    Providers,
    SeriesOps
  }

  # =============================================================================
  # Delegations to Sub-modules
  # =============================================================================

  # Favorites operations (polymorphic)
  defdelegate list_favorites(user_id, opts \\ []), to: Favorites, as: :list
  defdelegate favorite?(user_id, content_type, content_id), to: Favorites, as: :exists?
  defdelegate is_favorite?(user_id, content_type, content_id), to: Favorites
  defdelegate count_favorites_by_type(user_id), to: Favorites, as: :count_by_type
  defdelegate list_favorite_ids(user_id, content_type), to: Favorites, as: :list_ids
  defdelegate count_favorites(user_id), to: Favorites, as: :count
  defdelegate add_favorite(user_id, attrs), to: Favorites, as: :add

  defdelegate add_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :add

  defdelegate remove_favorite(user_id, content_type, content_id), to: Favorites, as: :remove

  defdelegate toggle_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :toggle

  # Watch History operations (polymorphic)
  defdelegate list_watch_history(user_id, opts \\ []), to: History, as: :list
  defdelegate count_watch_history_by_type(user_id), to: History, as: :count_by_type

  defdelegate add_watch_history(user_id, content_type, content_id, attrs \\ %{}),
    to: History,
    as: :add

  defdelegate add_to_watch_history(user_id, attrs), to: History, as: :add

  defdelegate update_progress(user_id, content_type, content_id, progress, duration \\ nil),
    to: History

  defdelegate update_watch_progress(user_id, content_type, content_id, current_time, duration),
    to: History

  defdelegate update_watch_time(user_id, content_type, content_id, duration_seconds), to: History
  defdelegate remove_from_watch_history(user_id, entry_id), to: History, as: :remove
  defdelegate clear_watch_history(user_id), to: History, as: :clear

  # Live Channels operations
  defdelegate list_live_channels(provider_id, opts \\ []), to: Channels, as: :list
  defdelegate list_public_channels(opts \\ []), to: Channels, as: :list_public
  defdelegate count_live_channels(provider_id), to: Channels, as: :count
  defdelegate get_live_channel!(id), to: Channels, as: :get!
  defdelegate get_live_channel(id), to: Channels, as: :get
  defdelegate get_channel(id), to: Channels, as: :get
  defdelegate get_user_live_channel(user_id, channel_id), to: Channels, as: :get_user_channel
  defdelegate get_playable_channel(user_id, channel_id), to: Channels, as: :get_playable
  defdelegate get_public_channel(channel_id), to: Channels, as: :get_public
  defdelegate get_live_channel_with_provider!(id), to: Channels, as: :get_with_provider!
  defdelegate search_channels(user_id, query, opts \\ []), to: Channels, as: :search
  defdelegate search_public_channels(query, opts \\ []), to: Channels, as: :search_public

  # Movies operations
  defdelegate list_movies(provider_id, opts \\ []), to: Movies, as: :list
  defdelegate list_public_movies(opts \\ []), to: Movies, as: :list_public
  defdelegate count_movies(provider_id), to: Movies, as: :count
  defdelegate get_movie!(id), to: Movies, as: :get!
  defdelegate get_movie(id), to: Movies, as: :get
  defdelegate get_user_movie(user_id, movie_id), to: Movies
  defdelegate get_playable_movie(user_id, movie_id), to: Movies, as: :get_playable
  defdelegate get_public_movie(movie_id), to: Movies, as: :get_public
  defdelegate get_movie_with_provider!(id), to: Movies, as: :get_with_provider!
  defdelegate fetch_movie_info(movie), to: Movies, as: :fetch_info
  defdelegate search_movies(user_id, query, opts \\ []), to: Movies, as: :search
  defdelegate search_public_movies(query, opts \\ []), to: Movies, as: :search_public

  # Series operations
  defdelegate list_series(provider_id, opts \\ []), to: SeriesOps, as: :list
  defdelegate list_public_series(opts \\ []), to: SeriesOps, as: :list_public
  defdelegate count_series(provider_id), to: SeriesOps, as: :count
  defdelegate get_series!(id), to: SeriesOps, as: :get!
  defdelegate get_series(id), to: SeriesOps, as: :get
  defdelegate get_public_series(series_id), to: SeriesOps, as: :get_public
  defdelegate get_series_with_seasons(id), to: SeriesOps, as: :get_with_seasons
  defdelegate get_series_with_seasons!(id), to: SeriesOps, as: :get_with_seasons!
  defdelegate get_series_with_sync!(id), to: SeriesOps, as: :get_with_sync!
  defdelegate fetch_series_info(series), to: SeriesOps, as: :fetch_info
  defdelegate search_series(user_id, query, opts \\ []), to: SeriesOps, as: :search
  defdelegate search_public_series(query, opts \\ []), to: SeriesOps, as: :search_public

  # Episode operations
  defdelegate get_episode!(id), to: SeriesOps
  defdelegate get_episode(id), to: SeriesOps
  defdelegate get_user_episode(user_id, episode_id), to: SeriesOps
  defdelegate get_playable_episode(user_id, episode_id), to: SeriesOps
  defdelegate get_public_episode(episode_id), to: SeriesOps
  defdelegate get_episode_with_context!(id), to: SeriesOps
  defdelegate list_season_episodes(season_id), to: SeriesOps
  defdelegate fetch_episode_info(episode), to: SeriesOps

  # Provider operations
  defdelegate list_providers(user_id), to: Providers, as: :list
  defdelegate list_visible_providers(user_id \\ nil), to: Providers, as: :list_visible
  defdelegate list_public_providers(), to: Providers, as: :list_public
  defdelegate get_provider!(id), to: Providers, as: :get!
  defdelegate get_provider(id), to: Providers, as: :get
  defdelegate get_user_provider(user_id, provider_id), to: Providers
  defdelegate get_public_provider(provider_id), to: Providers, as: :get_public
  defdelegate get_global_provider(), to: Providers, as: :get_global
  defdelegate get_playable_provider(user_id, provider_id), to: Providers, as: :get_playable
  defdelegate create_provider(attrs \\ %{}), to: Providers, as: :create
  defdelegate update_provider(provider, attrs), to: Providers, as: :update
  defdelegate delete_provider(provider), to: Providers, as: :delete
  defdelegate change_provider(provider, attrs \\ %{}), to: Providers, as: :change
  defdelegate test_connection(url, username, password), to: Providers
  defdelegate sync_provider(provider, opts \\ []), to: Providers, as: :sync
  defdelegate async_sync_provider(provider), to: Providers, as: :async_sync

  # Catalog operations (public content)
  defdelegate get_featured_content(), to: Catalog
  defdelegate get_public_stats(), to: Catalog

  defdelegate list_public_movies_by_genre(genre, opts \\ []),
    to: Catalog,
    as: :list_movies_by_genre

  defdelegate list_recently_added(opts \\ []), to: Catalog
  defdelegate list_categories(provider_id, type \\ nil), to: Catalog
  defdelegate get_category!(id), to: Catalog

  # EPG operations
  defdelegate get_now_and_next(provider_id, epg_channel_id), to: Epg
  defdelegate get_current_programs_batch(provider_id, epg_channel_ids), to: Epg
  defdelegate enrich_channels_with_epg(channels, provider_id), to: Epg
  defdelegate sync_channel_epg(provider, stream_id, epg_channel_id), to: Epg, as: :sync_channel
  defdelegate sync_channels_epg(provider, channels), to: Epg, as: :sync_channels
  defdelegate ensure_epg_available(provider, channels), to: Epg
end
