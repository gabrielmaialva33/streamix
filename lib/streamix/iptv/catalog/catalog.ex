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

  alias Streamix.Iptv.{
    AdultFilter,
    CatalogItem,
    Category,
    Episode,
    LiveChannel,
    Movie,
    MovieAsset,
    Provider,
    Season,
    Series,
    SeriesAsset,
    WatchProgress
  }

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
    seed = Date.utc_today() |> Date.to_gregorian_days()

    pick_featured(seed, [
      {:movie, &featured_movies_with_backdrop/0},
      {:series, &featured_series_with_backdrop/0},
      {:movie, &featured_movies_with_plot/0},
      {:movie, &featured_movies_any_poster/0}
    ])
  rescue
    e ->
      require Logger

      Logger.error("[IPTV] get_featured_content failed",
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # Walks the candidate list in order and returns the first {tag, item} hit.
  # Each candidate is {:movie | :series, fn -> list}; the list's element at
  # rem(seed, length) is returned — guarantees stable choice per day while
  # rotating across the top N items.
  defp pick_featured(_seed, []), do: nil

  defp pick_featured(seed, [{tag, fun} | rest]) do
    case fun.() do
      [] -> pick_featured(seed, rest)
      items -> {tag, Enum.at(items, rem(seed, length(items)))}
    end
  end

  defp featured_movies_with_backdrop do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> join(:inner, [m, _p], a in MovieAsset,
      on: a.movie_id == m.id and a.asset_type == "backdrop"
    )
    |> where([m, p, _a], p.visibility in [:global, :public])
    |> where([m, _p, _a], not is_nil(m.plot))
    |> order_by([m], fragment("? DESC NULLS LAST", m.rating))
    |> limit(10)
    |> distinct([m], m.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_series_with_backdrop do
    Series
    |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
    |> join(:inner, [s, _p], a in SeriesAsset,
      on: a.series_id == s.id and a.asset_type == "backdrop"
    )
    |> where([s, p, _a], p.visibility in [:global, :public])
    |> where([s, _p, _a], not is_nil(s.plot))
    |> order_by([s], fragment("? DESC NULLS LAST", s.rating))
    |> limit(10)
    |> distinct([s], s.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_movies_with_plot do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], not is_nil(m.stream_icon) and m.stream_icon != "")
    |> where([m, _p], not is_nil(m.plot) and m.plot != "")
    |> order_by([m], fragment("? DESC NULLS LAST", m.rating))
    |> limit(10)
    |> distinct([m], m.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_movies_any_poster do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], not is_nil(m.stream_icon) and m.stream_icon != "")
    |> order_by([m], fragment("? DESC NULLS LAST", m.rating))
    |> limit(10)
    |> distinct([m], m.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  # =============================================================================
  # Statistics
  # =============================================================================

  @doc """
  Gets total counts for public stats display.
  Only counts content from public/global providers.
  Results are cached for 30 minutes.
  """
  @spec get_public_stats(keyword()) :: %{String.t() => integer()}
  def get_public_stats(opts \\ []) do
    if Keyword.get(opts, :refresh, false) do
      refresh_public_stats()
    else
      Cache.fetch_public_stats(&compute_public_stats/0)
    end
  end

  defp refresh_public_stats do
    Cache.delete(Cache.public_stats_key())
    Cache.fetch_public_stats(&compute_public_stats/0)
  end

  defp compute_public_stats do
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
  end

  # =============================================================================
  # Public Listings
  # =============================================================================

  @doc """
  Lists canonical genres that have content of the given kind, ordered by
  content volume. Powers the genre sidebar on the unified browse pages.
  """
  @spec list_genres_for(:movies | :series) :: [%{id: integer(), name: String.t()}]
  def list_genres_for(kind) when kind in [:movies, :series] do
    Cache.fetch("catalog:genres:#{kind}", :timer.hours(6), fn ->
      genre_query_for(kind)
      |> group_by([g], [g.id, g.name])
      |> order_by([g], desc: count(), asc: g.name)
      |> select([g], %{id: g.id, name: g.name})
      |> Repo.all()
    end)
  end

  defp genre_query_for(:movies) do
    join(Streamix.Iptv.Genre, :inner, [g], link in "movie_genres", on: link.genre_id == g.id)
  end

  defp genre_query_for(:series) do
    join(Streamix.Iptv.Genre, :inner, [g], link in "series_genres", on: link.genre_id == g.id)
  end

  @doc """
  Lists movies by genre/category from public/global providers.
  """
  @spec list_movies_by_genre(String.t(), keyword()) :: [Movie.t()]
  def list_movies_by_genre(genre, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    escaped_genre = Helpers.escape_like(genre)

    public_movies_query()
    |> join(:inner, [movie: movie], movie_genre in "movie_genres",
      as: :movie_genre,
      on: movie_genre.movie_id == movie.id
    )
    |> join(:inner, [movie_genre: movie_genre], genre in Streamix.Iptv.Genre,
      as: :genre,
      on: genre.id == movie_genre.genre_id
    )
    |> where([genre: genre], ilike(genre.name, ^"%#{escaped_genre}%"))
    |> with_movie_poster()
    |> order_by([movie: movie], desc: movie.rating, desc: movie.year)
    |> limit(^limit)
    |> distinct([movie: movie], movie.id)
    |> select_movie_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Gets recently added movies from public/global providers.
  """
  @spec list_recent_movies(keyword()) :: [Movie.t()]
  def list_recent_movies(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    public_movies_query()
    |> with_movie_poster()
    |> order_by([movie: movie], desc: movie.inserted_at)
    |> limit(^limit)
    |> select_movie_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Gets recently added series from public/global providers.
  """
  @spec list_recent_series(keyword()) :: [Series.t()]
  def list_recent_series(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    public_series_query()
    |> with_series_cover()
    |> order_by([series: series], desc: series.inserted_at)
    |> limit(^limit)
    |> select_series_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Dispatches by content type: "movie" (default) or "series".
  """
  @spec list_trending(String.t(), keyword()) :: [Movie.t() | Series.t()]
  def list_trending("series", opts), do: list_trending_series(opts)
  def list_trending(_, opts), do: list_trending_movies(opts)

  @spec list_recent(String.t(), keyword()) :: [Movie.t() | Series.t()]
  def list_recent("series", opts), do: list_recent_series(opts)
  def list_recent(_, opts), do: list_recent_movies(opts)

  @spec list_top_rated(String.t(), keyword()) :: [Movie.t() | Series.t()]
  def list_top_rated("series", opts), do: list_top_10_series(opts)
  def list_top_rated(_, opts), do: list_top_10_movies(opts)

  @doc """
  Gets recently added content from public/global providers.
  Returns a mixed list of {:movie, movie} and {:series, series} tuples.
  """
  @spec list_recently_added(keyword()) :: [{:movie, Movie.t()} | {:series, Series.t()}]
  def list_recently_added(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    movies =
      public_movies_query()
      |> with_movie_poster()
      |> order_by([movie: movie], desc: movie.inserted_at)
      |> limit(^limit)
      |> select_movie_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.map(&{:movie, &1})

    series =
      public_series_query()
      |> with_series_cover()
      |> order_by([series: series], desc: series.inserted_at)
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
    offset = Keyword.get(opts, :offset, 0)
    days = Keyword.get(opts, :days, 7)
    show_adult = Keyword.get(opts, :show_adult, false)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    # Get movie IDs with watch counts from watch_progress via catalog_items
    trending_ids =
      from(progress in WatchProgress,
        as: :progress,
        join: catalog_item in CatalogItem,
        as: :catalog_item,
        on: progress.catalog_item_id == catalog_item.id,
        join: movie in Movie,
        as: :movie,
        on: movie.catalog_item_id == catalog_item.id,
        where: catalog_item.content_type == "movie",
        where: progress.last_watched_at >= ^since,
        group_by: movie.id,
        select: {movie.id, count(progress.id)},
        order_by: [desc: count(progress.id)],
        limit: ^((limit + offset) * 2)
      )
      |> Repo.all()
      |> Enum.map(fn {id, _count} -> id end)

    if trending_ids == [] do
      # Fallback to high-rated recent movies
      list_new_releases(limit: limit, offset: offset, show_adult: show_adult)
    else
      results =
        public_movies_query()
        |> maybe_exclude_adult(show_adult)
        |> where([movie: movie], movie.id in ^trending_ids)
        |> select_movie_card_fields()
        |> preload(^@summary_preloads)
        |> Repo.all()
        |> Enum.sort_by(fn m -> Enum.find_index(trending_ids, &(&1 == m.id)) end)
        |> Enum.drop(offset)
        |> Enum.take(limit)

      if results == [] do
        list_new_releases(limit: limit, offset: offset, show_adult: show_adult)
      else
        results
      end
    end
  end

  @doc """
  Gets trending series based on recent watch history.
  """
  @spec list_trending_series(keyword()) :: [Series.t()]
  def list_trending_series(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    # Get series IDs from episode watches via catalog_items.
    trending_series_ids =
      from(progress in WatchProgress,
        as: :progress,
        join: catalog_item in CatalogItem,
        as: :catalog_item,
        on: progress.catalog_item_id == catalog_item.id,
        join: episode in Episode,
        as: :episode,
        on: episode.catalog_item_id == catalog_item.id,
        join: season in Season,
        as: :season,
        on: season.id == episode.season_id,
        where: catalog_item.content_type == "episode",
        where: progress.last_watched_at >= ^since,
        group_by: season.series_id,
        select: {season.series_id, count(progress.id)},
        order_by: [desc: count(progress.id)],
        limit: ^((limit + offset) * 3)
      )
      |> Repo.all()

    if trending_series_ids == [] do
      # Fallback to high-rated series
      public_series_query()
      |> with_series_cover()
      |> order_by([series: series], desc: series.rating)
      |> offset(^offset)
      |> limit(^limit)
      |> select_series_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
    else
      series_ids = Enum.map(trending_series_ids, fn {id, _count} -> id end)

      public_series_query()
      |> where([series: series], series.id in ^series_ids)
      |> select_series_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.sort_by(fn series -> Enum.find_index(series_ids, &(&1 == series.id)) end)
      |> Enum.drop(offset)
      |> Enum.take(limit)
    end
  end

  @doc """
  Gets new releases (movies from 2024-2026 with good ratings).
  """
  @spec list_new_releases(keyword()) :: [Movie.t()]
  def list_new_releases(opts \\ []) do
    limit = Keyword.get(opts, :limit, 12)
    offset = Keyword.get(opts, :offset, 0)
    show_adult = Keyword.get(opts, :show_adult, false)
    current_year = Date.utc_today().year

    public_movies_query()
    |> maybe_exclude_adult(show_adult)
    |> where([movie: movie], movie.year >= ^(current_year - 2))
    |> with_movie_poster()
    |> order_by([movie: movie], desc: movie.year, desc: movie.rating)
    |> offset(^offset)
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
    offset = Keyword.get(opts, :offset, 0)

    # We used to require `plot` as well, but the gindex enrichment only
    # writes `stream_icon` + `tmdb_id` today (plot would need a second
    # TMDB call per title). Dropping that gate turns this query from
    # "returns 1 row" into "returns a proper top 10" — the card
    # component doesn't render plot anyway, it's rank + poster + title.
    public_movies_query()
    |> where([movie: movie], not is_nil(movie.rating))
    |> with_movie_poster()
    |> order_by([movie: movie], desc: movie.rating)
    |> offset(^offset)
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
    offset = Keyword.get(opts, :offset, 0)

    public_series_query()
    |> where([series: series], not is_nil(series.rating))
    |> with_series_cover()
    |> order_by([series: series], desc: series.rating)
    |> offset(^offset)
    |> limit(^limit)
    |> select_series_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  defp select_movie_card_fields(query) do
    select(query, [movie: movie], struct(movie, ^@movie_card_fields))
  end

  defp select_series_card_fields(query) do
    select(query, [series: series], struct(series, ^@series_card_fields))
  end

  defp public_movies_query do
    from(movie in Movie,
      as: :movie,
      join: provider in Provider,
      as: :provider,
      on: movie.provider_id == provider.id,
      where: provider.visibility in [:global, :public]
    )
  end

  defp public_series_query do
    from(series in Series,
      as: :series,
      join: provider in Provider,
      as: :provider,
      on: series.provider_id == provider.id,
      where: provider.visibility in [:global, :public]
    )
  end

  defp with_movie_poster(query), do: where(query, [movie: movie], not is_nil(movie.stream_icon))
  defp with_series_cover(query), do: where(query, [series: series], not is_nil(series.cover))

  defp maybe_exclude_adult(query, true), do: query

  defp maybe_exclude_adult(query, _show_adult),
    do: AdultFilter.exclude_adult_content(query, :movie)

  # =============================================================================
  # Categories
  # =============================================================================

  @doc """
  Lists categories for a provider, optionally filtered by type.
  """
  @spec list_categories(integer(), String.t() | nil) :: [Category.t()]
  def list_categories(provider_id, type \\ nil) do
    query = Category |> where(provider_id: ^provider_id)
    query = if type, do: where(query, type: ^type), else: query
    query |> order_by(:name) |> Repo.all()
  end

  @doc """
  Gets a category by ID. Raises if not found.
  """
  @spec get_category!(integer()) :: Category.t()
  def get_category!(id), do: Repo.get!(Category, id)
end
