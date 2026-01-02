defmodule Streamix.Iptv.Movies do
  @moduledoc """
  Movie operations.

  Provides listing, searching, and retrieval of VOD movies
  with proper access control based on provider visibility.
  Also handles fetching detailed movie info from external APIs.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Access, AdultFilter, Movie, TmdbClient, XtreamClient}
  alias Streamix.Repo

  # =============================================================================
  # Listing
  # =============================================================================

  @doc """
  Lists movies for a specific provider with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for movie name
    * `:category_id` - Filter by category ID
    * `:year` - Filter by release year
    * `:show_adult` - Include adult content (default: false)
  """
  @spec list(integer(), keyword()) :: [Movie.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    year = Keyword.get(opts, :year)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      Movie
      |> where(provider_id: ^provider_id)
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        where(query, [m], ilike(m.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [m], mc in "movie_categories",
          on: mc.movie_id == m.id and mc.category_id == ^category_id
        )
      else
        query
      end

    query = if year, do: where(query, year: ^year), else: query

    # Filter adult content unless user opts in
    query =
      if show_adult do
        query
      else
        AdultFilter.exclude_adult_movies(query, provider_id)
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists featured movies from public/global providers for public display.
  Orders by rating and recency.
  """
  @spec list_public(keyword()) :: [Movie.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Movie
    |> Access.public_providers()
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Counts movies for a provider.
  """
  @spec count(integer()) :: integer()
  def count(provider_id) do
    Movie
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  # =============================================================================
  # Retrieval
  # =============================================================================

  @doc """
  Gets a movie by ID. Raises if not found.
  """
  @spec get!(integer()) :: Movie.t()
  def get!(id), do: Repo.get!(Movie, id)

  @doc """
  Gets a movie by ID. Returns nil if not found.
  """
  @spec get(integer()) :: Movie.t() | nil
  def get(id), do: Repo.get(Movie, id)

  @doc """
  Gets a movie owned by a specific user.
  """
  @spec get_user_movie(integer(), integer()) :: Movie.t() | nil
  def get_user_movie(user_id, movie_id) do
    Movie
    |> Access.user_scoped(user_id, movie_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a movie if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  @spec get_playable(integer(), integer()) :: Movie.t() | nil
  def get_playable(user_id, movie_id) do
    Movie
    |> Access.playable(user_id, movie_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a movie from public providers only (for guests).
  """
  @spec get_public(integer()) :: Movie.t() | nil
  def get_public(movie_id) do
    Movie
    |> Access.public_only(movie_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a movie with preloaded provider. Raises if not found.
  """
  @spec get_with_provider!(integer()) :: Movie.t()
  def get_with_provider!(id) do
    Movie
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one!()
  end

  # =============================================================================
  # Search
  # =============================================================================

  @doc """
  Searches movies across all visible providers (global + public + user's private).
  """
  @spec search(integer(), String.t(), keyword()) :: [Movie.t()]
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Movie
    |> Access.visible_to_user(user_id)
    |> where([m, _p], ilike(m.name, ^"%#{query}%") or ilike(m.title, ^"%#{query}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches movies in public providers only (for guests).
  """
  @spec search_public(String.t(), keyword()) :: [Movie.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Movie
    |> Access.public_providers()
    |> where([m, _p], ilike(m.name, ^"%#{query}%") or ilike(m.title, ^"%#{query}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  # =============================================================================
  # Movie Info Fetching
  # =============================================================================

  @doc """
  Fetches detailed movie info from Xtream API and TMDB (as fallback).
  Returns {:ok, updated_movie} or {:error, reason}.

  Flow:
  1. Fetch from Xtream API (get_vod_info)
  2. If still missing key data (plot, cast, director) and tmdb_id is available, fetch from TMDB
  3. Merge all data and update the movie record
  """
  @spec fetch_info(Movie.t()) :: {:ok, Movie.t()} | {:error, term()}
  def fetch_info(%Movie{} = movie) do
    movie = Repo.preload(movie, :provider)
    provider = movie.provider

    # Step 1: Fetch from Xtream API
    xtream_attrs =
      case XtreamClient.get_vod_info(
             provider.url,
             provider.username,
             provider.password,
             movie.stream_id
           ) do
        {:ok, %{"info" => info, "movie_data" => movie_data}} ->
          parse_vod_info(info, movie_data)

        {:ok, %{"info" => info}} ->
          parse_vod_info(info, %{})

        {:ok, response} ->
          require Logger

          Logger.debug("[IPTV] Unexpected Xtream response format for movie #{movie.id}",
            response_keys: Map.keys(response)
          )

          %{}

        {:error, reason} ->
          require Logger

          Logger.warning("[IPTV] Xtream API failed for movie #{movie.id}",
            movie_name: movie.name,
            reason: inspect(reason)
          )

          %{}
      end

    # Step 2: Fetch from TMDB if we're still missing key data
    tmdb_id = xtream_attrs[:tmdb_id] || movie.tmdb_id
    tmdb_attrs = maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)

    # Step 3: Merge attrs (TMDB fills in what Xtream didn't provide)
    final_attrs = Map.merge(tmdb_attrs, xtream_attrs)

    update_movie(movie, final_attrs)
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)
       when is_binary(tmdb_id) and tmdb_id != "" do
    if needs_tmdb_enrichment?(movie, xtream_attrs) do
      fetch_from_tmdb(tmdb_id)
    else
      %{}
    end
  end

  defp maybe_fetch_from_tmdb(_movie, _xtream_attrs, _tmdb_id), do: %{}

  defp needs_tmdb_enrichment?(movie, xtream_attrs) do
    missing_basic_info?(movie, xtream_attrs) or missing_extended_info?(movie)
  end

  defp missing_basic_info?(movie, xtream_attrs) do
    missing_field?(xtream_attrs[:plot], movie.plot) or
      missing_field?(xtream_attrs[:cast], movie.cast) or
      missing_field?(xtream_attrs[:director], movie.director)
  end

  defp missing_extended_info?(movie) do
    is_nil(movie.content_rating) and is_nil(movie.tagline) and empty_images?(movie.images)
  end

  defp missing_field?(xtream_val, movie_val), do: is_nil(xtream_val) and is_nil(movie_val)
  defp empty_images?(nil), do: true
  defp empty_images?([]), do: true
  defp empty_images?(_), do: false

  defp fetch_from_tmdb(tmdb_id) do
    case TmdbClient.get_movie(tmdb_id) do
      {:ok, data} ->
        TmdbClient.parse_movie_response(data)

      {:error, reason} ->
        require Logger

        Logger.warning("[IPTV] TMDB API failed for tmdb_id #{tmdb_id}",
          reason: inspect(reason)
        )

        %{}

      _ ->
        %{}
    end
  end

  defp update_movie(movie, attrs) when attrs == %{}, do: {:ok, movie}

  defp update_movie(movie, attrs) do
    movie
    |> Movie.changeset(attrs)
    |> Repo.update()
  end

  defp parse_vod_info(info, movie_data) when is_map(info) do
    %{}
    |> maybe_put(:title, info["name"])
    |> maybe_put(:plot, info["plot"] || info["description"])
    |> maybe_put(:cast, info["cast"])
    |> maybe_put(:director, info["director"])
    |> maybe_put(:genre, info["genre"])
    |> maybe_put(:duration, info["duration"] || format_runtime(info["runtime"]))
    |> maybe_put(:duration_secs, parse_duration_secs(info["duration_secs"]))
    |> maybe_put(:rating, parse_decimal(info["rating"]))
    |> maybe_put(:rating_5based, parse_decimal(info["rating_5based"]))
    |> maybe_put(:year, parse_integer(info["releasedate"] || info["release_date"]))
    |> maybe_put(:tmdb_id, to_string_or_nil(info["tmdb_id"]))
    |> maybe_put(:imdb_id, info["kinopoisk_url"])
    |> maybe_put(:youtube_trailer, info["youtube_trailer"])
    |> maybe_put(:backdrop_path, parse_backdrop(info["backdrop_path"]))
    |> maybe_put(:stream_icon, info["cover_big"] || info["movie_image"])
    |> maybe_put(:container_extension, movie_data["container_extension"])
  end

  defp parse_vod_info(_, _), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(value) when is_number(value), do: Decimal.from_float(value / 1)
  defp parse_decimal(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: nil

  defp parse_duration_secs(nil), do: nil
  defp parse_duration_secs(value) when is_integer(value), do: value
  defp parse_duration_secs(value) when is_binary(value), do: parse_integer(value)
  defp parse_duration_secs(_), do: nil

  defp format_runtime(nil), do: nil
  defp format_runtime(""), do: nil

  defp format_runtime(runtime) when is_binary(runtime) do
    case Integer.parse(runtime) do
      {minutes, _} when minutes > 0 ->
        hours = div(minutes, 60)
        mins = rem(minutes, 60)
        if hours > 0, do: "#{hours}h #{mins}min", else: "#{mins}min"

      _ ->
        runtime
    end
  end

  defp format_runtime(_), do: nil

  defp parse_backdrop(nil), do: nil
  defp parse_backdrop([]), do: nil
  defp parse_backdrop(paths) when is_list(paths), do: paths
  defp parse_backdrop(path) when is_binary(path), do: [path]
  defp parse_backdrop(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_), do: nil
end
