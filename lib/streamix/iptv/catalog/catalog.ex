defmodule Streamix.Iptv.Catalog do
  @moduledoc """
  Public catalog operations.

  Provides featured content, statistics, and public listings
  for the homepage and unauthenticated users.
  All queries filter by public/global provider visibility.
  """

  import Ecto.Query, warn: false

  alias Streamix.Cache
  alias Streamix.Helpers
  alias Streamix.Iptv.{Category, LiveChannel, Movie, MovieAsset, Provider, Series, SeriesAsset}
  alias Streamix.Repo

  @summary_preloads [:genres]
  @featured_preloads [:assets, :genres]
  @movie_card_fields ~w(id name title year stream_icon rating inserted_at)a
  @series_card_fields ~w(id name title year cover rating inserted_at)a

  # =============================================================================
  # Featured Content
  # =============================================================================

  @doc """
  Gets a featured movie/series with backdrop for hero display.
  Uses a daily seed for consistency (same hero all day, changes at midnight).
  Only shows content from public/global providers.
  """
  @spec get_featured_content() :: {:movie, Movie.t()} | {:series, Series.t()} | nil
  def get_featured_content do
    # Daily seed for consistent hero throughout the day
    today = Date.utc_today()
    seed = Date.to_gregorian_days(today)

    # Try movies with backdrop first (from public/global providers)
    movies =
      Movie
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> join(:inner, [m, _p], a in MovieAsset,
        on: a.movie_id == m.id and a.asset_type == "backdrop"
      )
      |> where([m, p, _a], p.visibility in [:global, :public])
      |> where([m, _p, _a], not is_nil(m.plot))
      |> order_by([m], desc: m.rating)
      |> limit(10)
      |> distinct([m], m.id)
      |> preload(^@featured_preloads)
      |> Repo.all()

    if movies != [] do
      index = rem(seed, length(movies))
      {:movie, Enum.at(movies, index)}
    else
      # Fallback to series with backdrop (from public/global providers)
      series_list =
        Series
        |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
        |> join(:inner, [s, _p], a in SeriesAsset,
          on: a.series_id == s.id and a.asset_type == "backdrop"
        )
        |> where([s, p, _a], p.visibility in [:global, :public])
        |> where([s, _p, _a], not is_nil(s.plot))
        |> order_by([s], desc: s.rating)
        |> limit(10)
        |> distinct([s], s.id)
        |> preload(^@featured_preloads)
        |> Repo.all()

      if series_list != [] do
        index = rem(seed, length(series_list))
        {:series, Enum.at(series_list, index)}
      else
        # Final fallback: movies with stream_icon (no backdrop asset required)
        fallback_movies =
          Movie
          |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
          |> where([m, p], p.visibility in [:global, :public])
          |> where([m, _p], not is_nil(m.stream_icon) and m.stream_icon != "")
          |> where([m, _p], not is_nil(m.plot) and m.plot != "")
          |> order_by([m], desc: m.rating)
          |> limit(10)
          |> distinct([m], m.id)
          |> preload(^@featured_preloads)
          |> Repo.all()

        if fallback_movies != [] do
          index = rem(seed, length(fallback_movies))
          {:movie, Enum.at(fallback_movies, index)}
        else
          nil
        end
      end
    end
  rescue
    e ->
      require Logger

      Logger.error("[IPTV] get_featured_content failed",
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # =============================================================================
  # Statistics
  # =============================================================================

  @doc """
  Gets total counts for public stats display.
  Only counts content from public/global providers.
  Results are cached for 30 minutes.
  """
  @spec get_public_stats() :: %{String.t() => integer()}
  def get_public_stats do
    Cache.fetch_public_stats(fn ->
      channels_count =
        LiveChannel
        |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
        |> where([c, p], p.visibility in [:global, :public])
        |> Repo.aggregate(:count)

      movies_count =
        Movie
        |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
        |> where([m, p], p.visibility in [:global, :public])
        |> Repo.aggregate(:count)

      series_count =
        Series
        |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
        |> where([s, p], p.visibility in [:global, :public])
        |> Repo.aggregate(:count)

      %{
        channels_count: channels_count,
        movies_count: movies_count,
        series_count: series_count
      }
    end)
  end

  # =============================================================================
  # Public Listings
  # =============================================================================

  @doc """
  Lists movies by genre/category from public/global providers.
  """
  @spec list_movies_by_genre(String.t(), keyword()) :: [Movie.t()]
  def list_movies_by_genre(genre, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    escaped_genre = Helpers.escape_like(genre)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> join(:inner, [m, _p], mg in "movie_genres", on: mg.movie_id == m.id)
    |> join(:inner, [m, _p, mg], g in Streamix.Iptv.Genre, on: g.id == mg.genre_id)
    |> where([m, p, _mg, _g], p.visibility in [:global, :public])
    |> where([m, _p, _mg, g], ilike(g.name, ^"%#{escaped_genre}%"))
    |> where([m, _p, _mg, _g], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year)
    |> limit(^limit)
    |> distinct([m], m.id)
    |> select_movie_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Gets recently added content from public/global providers.
  Returns a mixed list of {:movie, movie} and {:series, series} tuples.
  """
  @spec list_recently_added(keyword()) :: [{:movie, Movie.t()} | {:series, Series.t()}]
  def list_recently_added(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    movies =
      Movie
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.visibility in [:global, :public])
      |> where([m, _p], not is_nil(m.stream_icon))
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> select_movie_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.map(&{:movie, &1})

    series =
      Series
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> where([s, _p], not is_nil(s.cover))
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)
      |> select_series_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.map(&{:series, &1})

    (movies ++ series)
    |> Enum.sort_by(fn {_type, item} -> item.inserted_at end, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # =============================================================================
  # Trending & Top 10 (Netflix-style)
  # =============================================================================

  @doc """
  Gets trending movies based on recent watch history (last 7 days).
  More watches = higher trending score.
  """
  @spec list_trending_movies(keyword()) :: [Movie.t()]
  def list_trending_movies(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    # Get movie IDs with watch counts from watch_progress via catalog_items
    trending_ids =
      from(wp in Streamix.Iptv.WatchProgress,
        join: ci in Streamix.Iptv.CatalogItem,
        on: wp.catalog_item_id == ci.id,
        join: m in Streamix.Iptv.Movie,
        on: m.catalog_item_id == ci.id,
        where: ci.content_type == "movie",
        where: wp.last_watched_at >= ^since,
        group_by: m.id,
        select: {m.id, count(wp.id)},
        order_by: [desc: count(wp.id)],
        limit: ^(limit * 2)
      )
      |> Repo.all()
      |> Enum.map(fn {id, _count} -> id end)

    if trending_ids == [] do
      # Fallback to high-rated recent movies
      list_new_releases(limit: limit)
    else
      Movie
      |> where([m], m.id in ^trending_ids)
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.visibility in [:global, :public])
      |> select_movie_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.sort_by(fn m -> Enum.find_index(trending_ids, &(&1 == m.id)) end)
      |> Enum.take(limit)
    end
  end

  @doc """
  Gets trending series based on recent watch history.
  """
  @spec list_trending_series(keyword()) :: [Series.t()]
  def list_trending_series(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    # Get series IDs from episode watches via catalog_items
    trending_episode_ids =
      from(wp in Streamix.Iptv.WatchProgress,
        join: ci in Streamix.Iptv.CatalogItem,
        on: wp.catalog_item_id == ci.id,
        join: e in Streamix.Iptv.Episode,
        on: e.catalog_item_id == ci.id,
        where: ci.content_type == "episode",
        where: wp.last_watched_at >= ^since,
        group_by: e.id,
        select: {e.id, count(wp.id)},
        order_by: [desc: count(wp.id)],
        limit: ^(limit * 3)
      )
      |> Repo.all()

    if trending_episode_ids == [] do
      # Fallback to high-rated series
      Series
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> where([s, _p], not is_nil(s.cover))
      |> order_by([s], desc: s.rating)
      |> limit(^limit)
      |> select_series_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
    else
      # Map episode IDs to series IDs
      episode_ids = Enum.map(trending_episode_ids, fn {id, _} -> id end)

      series_ids =
        from(e in Streamix.Iptv.Episode,
          where: e.id in ^episode_ids,
          join: s in Streamix.Iptv.Season,
          on: e.season_id == s.id,
          select: s.series_id,
          distinct: true
        )
        |> Repo.all()

      Series
      |> where([s], s.id in ^series_ids)
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> select_series_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.take(limit)
    end
  end

  @doc """
  Gets new releases (movies from 2024-2026 with good ratings).
  """
  @spec list_new_releases(keyword()) :: [Movie.t()]
  def list_new_releases(opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    current_year = Date.utc_today().year

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], m.year >= ^(current_year - 2))
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.year, desc: m.rating)
    |> limit(^limit)
    |> select_movie_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Gets Top 10 movies (highest rated with good data).
  Netflix-style numbered list.
  """
  @spec list_top_10_movies(keyword()) :: [Movie.t()]
  def list_top_10_movies(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], not is_nil(m.rating))
    |> where([m, _p], not is_nil(m.stream_icon))
    |> where([m, _p], not is_nil(m.plot))
    |> order_by([m], desc: m.rating)
    |> limit(^limit)
    |> select_movie_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Gets Top 10 series.
  """
  @spec list_top_10_series(keyword()) :: [Series.t()]
  def list_top_10_series(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    Series
    |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
    |> where([s, p], p.visibility in [:global, :public])
    |> where([s, _p], not is_nil(s.rating))
    |> where([s, _p], not is_nil(s.cover))
    |> order_by([s], desc: s.rating)
    |> limit(^limit)
    |> select_series_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  defp select_movie_card_fields(query) do
    select(query, [m], struct(m, ^@movie_card_fields))
  end

  defp select_series_card_fields(query) do
    select(query, [s], struct(s, ^@series_card_fields))
  end

  # =============================================================================
  # Categories
  # =============================================================================

  @doc """
  Lists categories for a provider, optionally filtered by type.
  Results are cached.
  """
  @spec list_categories(integer(), String.t() | nil) :: [Category.t()]
  def list_categories(provider_id, type \\ nil) do
    Cache.fetch_categories(provider_id, type, fn ->
      query = Category |> where(provider_id: ^provider_id)
      query = if type, do: where(query, type: ^type), else: query
      query |> order_by(:name) |> Repo.all()
    end)
  end

  @doc """
  Gets a category by ID. Raises if not found.
  """
  @spec get_category!(integer()) :: Category.t()
  def get_category!(id), do: Repo.get!(Category, id)
end
