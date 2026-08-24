defmodule Streamix.Catalog do
  @moduledoc """
  Application boundary for browsing and reading the canonical media catalog.

  Delivery layers use this module for movies, series, episodes, live channels,
  categories, curated shelves, GIndex catalog views, and display metadata.
  The implementation modules under `Streamix.Iptv.*` remain internal details;
  callers must not depend on the historical `Streamix.Iptv` facade.
  """

  alias Streamix.Iptv.{Assets, CatalogItem, Channels, ContentRef, Movies, SeriesOps}
  alias Streamix.Iptv.Catalog, as: CatalogStore

  # Home and discovery

  defdelegate get_featured_content(opts \\ []), to: CatalogStore
  defdelegate get_public_stats(opts \\ []), to: CatalogStore
  defdelegate list_new_releases(opts), to: CatalogStore
  defdelegate list_recent(content_type, opts), to: CatalogStore
  defdelegate list_top_10_movies(opts), to: CatalogStore
  defdelegate list_top_10_series(opts), to: CatalogStore
  defdelegate list_top_rated(content_type, opts), to: CatalogStore
  defdelegate list_trending(content_type, opts), to: CatalogStore
  defdelegate list_trending_movies(opts), to: CatalogStore

  # Categories and visual metadata

  defdelegate backdrop_urls(content), to: Assets
  defdelegate has_images?(content), to: Assets
  defdelegate image_urls(content), to: Assets
  defdelegate list_categories(provider_id, type \\ nil), to: CatalogStore
  defdelegate list_public_categories(opts \\ []), to: CatalogStore

  # Movies

  defdelegate count_public_catalog_movies(opts), to: Movies, as: :count_public_catalog
  defdelegate fetch_movie_info(movie), to: Movies, as: :fetch_info
  defdelegate get_movie(id), to: Movies, as: :get
  defdelegate get_movie!(id), to: Movies, as: :get!
  defdelegate get_movie_with_provider!(id), to: Movies, as: :get_with_provider!
  defdelegate get_movies_by_ids(ids), to: Movies, as: :get_by_ids
  defdelegate get_public_movie(id), to: Movies, as: :get_public
  defdelegate list_movies(provider_id, opts), to: Movies, as: :list
  defdelegate list_public_catalog_movies(opts), to: Movies, as: :list_public_catalog
  defdelegate list_public_movies(opts), to: Movies, as: :list_public
  defdelegate list_public_movies_by_ids(ids, opts \\ []), to: Movies, as: :list_public_by_ids
  defdelegate list_visible_movies(user_id, opts), to: Movies, as: :list_visible

  defdelegate list_visible_movies_by_ids(user_id, ids, opts \\ []),
    to: Movies,
    as: :list_visible_by_ids

  # Series and episodes

  defdelegate count_public_catalog_series(opts), to: SeriesOps, as: :count_public_catalog
  defdelegate fetch_episode_info(episode), to: SeriesOps
  defdelegate fetch_series_info(series), to: SeriesOps, as: :fetch_info
  defdelegate get_episode_with_context!(id), to: SeriesOps
  defdelegate get_next_episode(episode), to: SeriesOps
  defdelegate get_public_episode(id), to: SeriesOps
  defdelegate get_public_series(id), to: SeriesOps, as: :get_public
  defdelegate get_series!(id), to: SeriesOps, as: :get!
  defdelegate get_series_by_ids(ids), to: SeriesOps, as: :get_by_ids
  defdelegate get_series_with_sync!(id), to: SeriesOps, as: :get_with_sync!
  defdelegate list_public_catalog_series(opts), to: SeriesOps, as: :list_public_catalog
  defdelegate list_public_series(opts), to: SeriesOps, as: :list_public

  defdelegate list_public_series_by_ids(ids, opts \\ []),
    to: SeriesOps,
    as: :list_public_by_ids

  defdelegate list_season_episodes(season_id), to: SeriesOps
  defdelegate list_series(provider_id, opts), to: SeriesOps, as: :list
  defdelegate list_visible_series(user_id, opts), to: SeriesOps, as: :list_visible

  defdelegate list_visible_series_by_ids(user_id, ids, opts \\ []),
    to: SeriesOps,
    as: :list_visible_by_ids

  # Live channels

  defdelegate count_public_catalog_channels(opts), to: Channels, as: :count_public_catalog
  defdelegate get_public_channel(id), to: Channels, as: :get_public
  defdelegate list_live_channels(provider_id, opts \\ []), to: Channels, as: :list
  defdelegate list_public_catalog_channels(opts), to: Channels, as: :list_public_catalog
  defdelegate list_public_channels(opts), to: Channels, as: :list_public
  defdelegate list_visible_live_channels(user_id, opts \\ []), to: Channels, as: :list_visible

  # GIndex-backed catalog views

  defdelegate get_gindex_anime_with_seasons(id), to: SeriesOps
  defdelegate get_gindex_series_with_seasons(id), to: SeriesOps, as: :get_gindex_with_seasons
  defdelegate list_gindex_animes(opts), to: SeriesOps
  defdelegate list_gindex_movies(opts), to: Movies, as: :list_gindex
  defdelegate list_gindex_series(opts), to: SeriesOps, as: :list_gindex

  @doc "Returns all GIndex content counts in one catalog query boundary."
  @spec gindex_counts() :: %{
          movies: non_neg_integer(),
          series: non_neg_integer(),
          animes: non_neg_integer()
        }
  def gindex_counts do
    %{
      movies: Movies.count_gindex(),
      series: SeriesOps.count_gindex(),
      animes: SeriesOps.count_gindex_animes()
    }
  end

  # Canonical catalog identity

  defdelegate get_catalog_item_with_content(catalog_item_id), to: CatalogStore
  defdelegate catalog_item_content(item), to: CatalogItem, as: :content
  defdelegate catalog_item_content_icon(item), to: CatalogItem, as: :content_icon
  defdelegate catalog_item_content_name(item), to: CatalogItem, as: :content_name
  defdelegate resolve_catalog_item_id(content_type, content_id), to: ContentRef
end
