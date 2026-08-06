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

  @summary_preloads [:provider, :genres]
  @featured_preloads [:provider, :assets, :genres]
  @catalog_item_content_preloads [:movie, :series, :episode, :live_channel]
  @movie_card_fields ~w(id provider_id name title year stream_icon rating inserted_at)a
  @series_card_fields ~w(id provider_id name title year cover rating inserted_at)a

  @doc """
  Gets one catalog item with its concrete content association loaded.
  """
  @spec get_catalog_item_with_content(integer()) :: CatalogItem.t() | nil
  def get_catalog_item_with_content(catalog_item_id) when is_integer(catalog_item_id) do
    case Repo.get(CatalogItem, catalog_item_id) do
      nil -> nil
      %CatalogItem{} = catalog_item -> Repo.preload(catalog_item, @catalog_item_content_preloads)
    end
  end

  # =============================================================================
  # Featured Content
  # =============================================================================

  @doc """
  Gets a featured movie/series with backdrop for hero display.
  Uses a daily seed for consistency (same hero all day, changes at midnight).
  Only shows content from public/global providers.
  """
  @spec get_featured_content(keyword()) :: {:movie, Movie.t()} | {:series, Series.t()} | nil
  def get_featured_content(opts \\ []) do
    seed = Date.utc_today() |> Date.to_gregorian_days()

    pick_featured(seed, [
      {:movie, fn -> featured_movies_with_backdrop(opts) end},
      {:series, fn -> featured_series_with_backdrop(opts) end},
      {:movie, fn -> featured_movies_with_plot(opts) end},
      {:movie, fn -> featured_movies_any_poster(opts) end}
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

  defp featured_movies_with_backdrop(opts) do
    public_movies_query()
    |> with_provider_filters(opts)
    |> join(:inner, [movie: movie], asset in MovieAsset,
      as: :asset,
      on: asset.movie_id == movie.id and asset.asset_type == "backdrop"
    )
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false), :movie)
    |> where([movie: movie], not is_nil(movie.plot))
    |> order_by([movie: movie], fragment("? DESC NULLS LAST", movie.rating))
    |> limit(10)
    |> distinct([movie: movie], movie.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_series_with_backdrop(opts) do
    public_series_query()
    |> with_provider_filters(opts)
    |> join(:inner, [series: series], asset in SeriesAsset,
      as: :asset,
      on: asset.series_id == series.id and asset.asset_type == "backdrop"
    )
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false), :series)
    |> where([series: series], not is_nil(series.plot))
    |> order_by([series: series], fragment("? DESC NULLS LAST", series.rating))
    |> limit(10)
    |> distinct([series: series], series.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_movies_with_plot(opts) do
    public_movies_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false), :movie)
    |> where([movie: movie], not is_nil(movie.stream_icon) and movie.stream_icon != "")
    |> where([movie: movie], not is_nil(movie.plot) and movie.plot != "")
    |> order_by([movie: movie], fragment("? DESC NULLS LAST", movie.rating))
    |> limit(10)
    |> distinct([movie: movie], movie.id)
    |> preload(^@featured_preloads)
    |> Repo.all()
  end

  defp featured_movies_any_poster(opts) do
    public_movies_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false), :movie)
    |> where([movie: movie], not is_nil(movie.stream_icon) and movie.stream_icon != "")
    |> order_by([movie: movie], fragment("? DESC NULLS LAST", movie.rating))
    |> limit(10)
    |> distinct([movie: movie], movie.id)
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
    cond do
      provider_filtered?(opts) -> compute_public_stats(opts)
      Keyword.get(opts, :refresh, false) -> refresh_public_stats()
      true -> Cache.fetch_public_stats(&compute_public_stats/0)
    end
  end

  defp refresh_public_stats do
    Cache.delete(Cache.public_stats_key())
    Cache.fetch_public_stats(&compute_public_stats/0)
  end

  defp compute_public_stats(opts \\ []) do
    channels_count =
      LiveChannel
      |> join(:inner, [channel], provider in Provider,
        as: :provider,
        on: channel.provider_id == provider.id
      )
      |> where(
        [provider: provider],
        provider.visibility in [:global, :public] and provider.is_active == true
      )
      |> with_provider_filters(opts)
      |> Repo.aggregate(:count)

    movies_count =
      Movie
      |> join(:inner, [movie], provider in Provider,
        as: :provider,
        on: movie.provider_id == provider.id
      )
      |> where(
        [provider: provider],
        provider.visibility in [:global, :public] and provider.is_active == true
      )
      |> with_provider_filters(opts)
      |> Repo.aggregate(:count)

    series_count =
      Series
      |> join(:inner, [series], provider in Provider,
        as: :provider,
        on: series.provider_id == provider.id
      )
      |> where(
        [provider: provider],
        provider.visibility in [:global, :public] and provider.is_active == true
      )
      |> with_provider_filters(opts)
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
    show_adult = Keyword.get(opts, :show_adult, false)
    escaped_genre = Helpers.escape_like(genre)

    public_movies_query()
    |> with_provider_filters(opts)
    |> join(:inner, [movie: movie], movie_genre in "movie_genres",
      as: :movie_genre,
      on: movie_genre.movie_id == movie.id
    )
    |> join(:inner, [movie_genre: movie_genre], genre in Streamix.Iptv.Genre,
      as: :genre,
      on: genre.id == movie_genre.genre_id
    )
    |> where([genre: genre], ilike(genre.name, ^"%#{escaped_genre}%"))
    |> maybe_exclude_adult(show_adult, :movie)
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
    show_adult = Keyword.get(opts, :show_adult, false)

    public_movies_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(show_adult, :movie)
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
    show_adult = Keyword.get(opts, :show_adult, false)

    public_series_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(show_adult, :series)
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
    show_adult = Keyword.get(opts, :show_adult, false)

    movies =
      public_movies_query()
      |> with_provider_filters(opts)
      |> maybe_exclude_adult(show_adult, :movie)
      |> with_movie_poster()
      |> order_by([movie: movie], desc: movie.inserted_at)
      |> limit(^limit)
      |> select_movie_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Enum.map(&{:movie, &1})

    series =
      public_series_query()
      |> with_provider_filters(opts)
      |> maybe_exclude_adult(show_adult, :series)
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
        group_by: movie.id,
        select: {movie.id, count(progress.id)},
        order_by: [desc: count(progress.id)],
        limit: ^((limit + offset) * 2)
      )
      |> maybe_since(days)
      |> Repo.all()
      |> Enum.map(fn {id, _count} -> id end)

    if trending_ids == [] do
      # Fallback to high-rated recent movies
      list_new_releases(shelf_opts(opts, limit, offset, show_adult))
    else
      results =
        public_movies_query()
        |> with_provider_filters(opts)
        |> maybe_exclude_adult(show_adult, :movie)
        |> where([movie: movie], movie.id in ^trending_ids)
        |> select_movie_card_fields()
        |> preload(^@summary_preloads)
        |> Repo.all()
        |> Enum.sort_by(fn m -> Enum.find_index(trending_ids, &(&1 == m.id)) end)
        |> Enum.drop(offset)
        |> Enum.take(limit)

      if results == [] do
        list_new_releases(shelf_opts(opts, limit, offset, show_adult))
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
    show_adult = Keyword.get(opts, :show_adult, false)

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
        group_by: season.series_id,
        select: {season.series_id, count(progress.id)},
        order_by: [desc: count(progress.id)],
        limit: ^((limit + offset) * 3)
      )
      |> maybe_since(days)
      |> Repo.all()

    if trending_series_ids == [] do
      # Fallback to high-rated series
      public_series_query()
      |> with_provider_filters(opts)
      |> maybe_exclude_adult(show_adult, :series)
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
      |> with_provider_filters(opts)
      |> maybe_exclude_adult(show_adult, :series)
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
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(show_adult, :movie)
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
    show_adult = Keyword.get(opts, :show_adult, false)

    # We used to require `plot` as well, but the gindex enrichment only
    # writes `stream_icon` + `tmdb_id` today (plot would need a second
    # TMDB call per title). Dropping that gate turns this query from
    # "returns 1 row" into "returns a proper top 10" — the card
    # component doesn't render plot anyway, it's rank + poster + title.
    public_movies_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(show_adult, :movie)
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
    show_adult = Keyword.get(opts, :show_adult, false)

    public_series_query()
    |> with_provider_filters(opts)
    |> maybe_exclude_adult(show_adult, :series)
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
      where: provider.visibility in [:global, :public] and provider.is_active == true
    )
  end

  defp public_series_query do
    from(series in Series,
      as: :series,
      join: provider in Provider,
      as: :provider,
      on: series.provider_id == provider.id,
      where: provider.visibility in [:global, :public] and provider.is_active == true
    )
  end

  defp with_provider_filters(query, opts) do
    query
    |> maybe_filter_provider(Keyword.get(opts, :provider_id))
    |> maybe_filter_provider_type(Keyword.get(opts, :provider_type))
  end

  defp provider_filtered?(opts) do
    not is_nil(Keyword.get(opts, :provider_id)) or
      not is_nil(Keyword.get(opts, :provider_type))
  end

  defp shelf_opts(opts, limit, offset, show_adult) do
    opts
    |> Keyword.put(:limit, limit)
    |> Keyword.put(:offset, offset)
    |> Keyword.put(:show_adult, show_adult)
  end

  defp with_movie_poster(query), do: where(query, [movie: movie], not is_nil(movie.stream_icon))
  defp with_series_cover(query), do: where(query, [series: series], not is_nil(series.cover))

  defp maybe_exclude_adult(query, true, _binding), do: query

  defp maybe_exclude_adult(query, _show_adult, binding),
    do: AdultFilter.exclude_adult_content(query, binding)

  defp maybe_since(query, nil), do: query

  defp maybe_since(query, days) when is_integer(days) and days > 0 do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)
    where(query, [progress: progress], progress.last_watched_at >= ^since)
  end

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
  Lists non-adult categories across active public/global providers.

  `:provider_id` and `:provider_type` narrow the source without ever making a
  private or inactive provider visible.
  """
  @spec list_public_categories(keyword()) :: [Category.t()]
  def list_public_categories(opts \\ []) do
    Category
    |> join(:inner, [category], provider in Provider,
      as: :provider,
      on: category.provider_id == provider.id
    )
    |> where(
      [category, provider: provider],
      provider.visibility in [:global, :public] and provider.is_active == true and
        category.is_adult == false
    )
    |> maybe_filter_provider(Keyword.get(opts, :provider_id))
    |> maybe_filter_provider_type(Keyword.get(opts, :provider_type))
    |> maybe_filter_category_type(Keyword.get(opts, :type))
    |> order_by([category, provider: provider],
      asc: provider.name,
      asc: category.name,
      asc: category.id
    )
    |> preload(:provider)
    |> Repo.all()
  end

  defp maybe_filter_provider(query, nil), do: query

  defp maybe_filter_provider(query, provider_id),
    do: where(query, [provider: provider], provider.id == ^provider_id)

  defp maybe_filter_provider_type(query, nil), do: query

  defp maybe_filter_provider_type(query, provider_type),
    do: where(query, [provider: provider], provider.provider_type == ^provider_type)

  defp maybe_filter_category_type(query, nil), do: query

  defp maybe_filter_category_type(query, type),
    do: where(query, [category], category.type == ^type)

  @doc """
  Gets a category by ID. Raises if not found.
  """
  @spec get_category!(integer()) :: Category.t()
  def get_category!(id), do: Repo.get!(Category, id)
end
