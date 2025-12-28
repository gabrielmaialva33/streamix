defmodule Streamix.Iptv.Catalog do
  @moduledoc """
  Public catalog operations.

  Provides featured content, statistics, and public listings
  for the homepage and unauthenticated users.
  All queries filter by public/global provider visibility.
  """

  import Ecto.Query, warn: false

  alias Streamix.Cache
  alias Streamix.Iptv.{Category, LiveChannel, Movie, Provider, Series}
  alias Streamix.Repo

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
      |> where([m, p], p.visibility in [:global, :public])
      |> where([m, _p], not is_nil(m.backdrop_path) and m.backdrop_path != ^[])
      |> where([m, _p], not is_nil(m.plot))
      |> order_by([m], desc: m.rating)
      |> limit(10)
      |> Repo.all()

    if movies != [] do
      index = rem(seed, length(movies))
      {:movie, Enum.at(movies, index)}
    else
      # Fallback to series with backdrop (from public/global providers)
      series_list =
        Series
        |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
        |> where([s, p], p.visibility in [:global, :public])
        |> where([s, _p], not is_nil(s.backdrop_path) and s.backdrop_path != ^[])
        |> where([s, _p], not is_nil(s.plot))
        |> order_by([s], desc: s.rating)
        |> limit(10)
        |> Repo.all()

      if series_list != [] do
        index = rem(seed, length(series_list))
        {:series, Enum.at(series_list, index)}
      else
        nil
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
        "channels_count" => channels_count,
        "movies_count" => movies_count,
        "series_count" => series_count
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

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], ilike(m.genre, ^"%#{genre}%"))
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year)
    |> limit(^limit)
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
      |> Repo.all()
      |> Enum.map(&{:movie, &1})

    series =
      Series
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> where([s, _p], not is_nil(s.cover))
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&{:series, &1})

    (movies ++ series)
    |> Enum.sort_by(fn {_type, item} -> item.inserted_at end, {:desc, DateTime})
    |> Enum.take(limit)
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
