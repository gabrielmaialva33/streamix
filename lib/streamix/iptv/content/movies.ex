defmodule Streamix.Iptv.Movies do
  @moduledoc """
  Movie operations.

  Provides listing, searching, and retrieval of VOD movies
  with proper access control based on provider visibility.
  Also handles fetching detailed movie info from external APIs.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers

  alias Streamix.Iptv.{
    Access,
    AdultFilter,
    Movie,
    MovieAsset,
    RankedSearch,
    TmdbClient,
    XtreamClient
  }

  alias Streamix.Repo

  @summary_preloads [:genres]
  @search_result_preloads [:assets, :genres]
  @detail_preloads [:assets, :genres, credits: :person]

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
    sort = Keyword.get(opts, :sort)

    query =
      Movie
      |> where(provider_id: ^provider_id)
      |> apply_movie_sort(sort)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [m], ilike(m.name, ^"%#{escaped}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [m], ic in "item_categories",
          on: ic.catalog_item_id == m.catalog_item_id and ic.category_id == ^category_id
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
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  # Sort order for public movie lists.
  # Supported: rating_desc | created_desc | year_desc | name_asc.
  # Default (nil/unknown): desc year, asc name.
  defp apply_movie_sort(query, "rating_desc"),
    do: order_by(query, [m], [fragment("? DESC NULLS LAST", m.rating), desc: m.year, asc: m.name])

  defp apply_movie_sort(query, "created_desc"),
    do: order_by(query, [m], desc: m.inserted_at)

  defp apply_movie_sort(query, "year_desc"),
    do: order_by(query, [m], [fragment("? DESC NULLS LAST", m.year), asc: m.name])

  defp apply_movie_sort(query, "name_asc"), do: order_by(query, [m], asc: m.name)
  defp apply_movie_sort(query, _), do: order_by(query, [m], desc: m.year, asc: m.name)

  @doc """
  Lists GIndex movies (movies with gindex_path set).

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for movie name
    * `:year` - Filter by release year
    * `:show_adult` - Include adult content (default: false)
  """
  @spec list_gindex(keyword()) :: [Movie.t()]
  def list_gindex(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    year = Keyword.get(opts, :year)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      Movie
      |> where([m], not is_nil(m.gindex_path))
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        search_term = "%#{escaped}%"
        where(query, [m], ilike(m.name, ^search_term) or ilike(m.title, ^search_term))
      else
        query
      end

    query = if year, do: where(query, year: ^year), else: query

    # Filter adult content (basic check on name)
    query =
      if show_adult do
        query
      else
        where(query, [m], not ilike(m.name, "%xxx%") and not ilike(m.name, "%adult%"))
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Counts GIndex movies.
  """
  @spec count_gindex() :: integer()
  def count_gindex do
    Movie
    |> where([m], not is_nil(m.gindex_path))
    |> Repo.aggregate(:count)
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
    |> preload(^@summary_preloads)
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
  def get(id) do
    Movie
    |> where(id: ^id)
    |> preload(^@detail_preloads)
    |> Repo.one()
  end

  @doc """
  Gets a movie for stream resolution with only the provider preloaded.
  """
  @spec get_for_stream(integer()) :: Movie.t() | nil
  def get_for_stream(id) do
    Movie
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets multiple movies by their IDs.
  Returns movies in arbitrary order.
  """
  @spec get_by_ids([integer()]) :: [Movie.t()]
  def get_by_ids([]), do: []

  def get_by_ids(ids) when is_list(ids) do
    from(m in Movie, where: m.id in ^ids)
    |> preload(^@search_result_preloads)
    |> Repo.all()
  end

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
    |> preload(^[:provider | @detail_preloads])
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
    escaped = Helpers.escape_like(query)

    Movie
    |> Access.visible_to_user(user_id)
    |> where([m, _p], ilike(m.name, ^"%#{escaped}%") or ilike(m.title, ^"%#{escaped}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Searches movies in public providers only (for guests).

  Uses `Streamix.Iptv.RankedSearch` so the result set is ordered by
  relevance (exact > prefix > substring > trigram-similarity) and
  includes a `:rank_score` virtual field on each struct. Queries like
  `"pokemon"` match `"Pokémon"` (unaccent) and `"Matris"` still finds
  `"Matrix"` (trigram).
  """
  @spec search_public(String.t(), keyword()) :: [Movie.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Movie
    |> Access.public_providers()
    |> RankedSearch.build([:name, :title], query, limit: limit)
    |> preload(^@summary_preloads)
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
    movie = Repo.preload(movie, [:provider | @detail_preloads])

    # Step 1: Fetch from Xtream API
    xtream_attrs = fetch_xtream_attrs(movie)

    # Step 2: Resolve a tmdb_id. Prefer what Xtream returned, then what we
    # already have stored, and finally fall back to a name+year search on
    # TMDB so titles from providers that don't ship tmdb_id still get
    # enriched on their first enrichment run.
    resolved_tmdb_id =
      xtream_attrs[:tmdb_id] || movie.tmdb_id || resolve_movie_tmdb_id(movie)

    # Persist the resolved id so the next enrichment skips the search.
    xtream_attrs =
      if is_binary(resolved_tmdb_id) and resolved_tmdb_id != "" and
           is_nil(xtream_attrs[:tmdb_id]) do
        Map.put(xtream_attrs, :tmdb_id, resolved_tmdb_id)
      else
        xtream_attrs
      end

    # Step 3: Fetch from TMDB if we're still missing key data
    tmdb_attrs = maybe_fetch_from_tmdb(movie, xtream_attrs, resolved_tmdb_id)

    # Step 4: Merge attrs (TMDB fills in what Xtream didn't provide)
    final_attrs = Map.merge(tmdb_attrs, xtream_attrs)

    case update_movie(movie, final_attrs) do
      {:ok, updated} -> {:ok, Repo.preload(updated, @detail_preloads, force: true)}
      error -> error
    end
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp fetch_xtream_attrs(%Movie{provider: provider} = movie) do
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
  end

  # Resolves a tmdb_id by searching TMDB with the movie's title + year.
  # When the movie has a year, we only trust matches whose release_date
  # falls within ±1 year to avoid accidentally binding to an unrelated
  # title with the same name.
  defp resolve_movie_tmdb_id(%Movie{} = movie) do
    title = movie.title || movie.name

    if is_binary(title) and title != "" do
      with {:ok, %{"results" => results}} when is_list(results) <-
             TmdbClient.search_movie(title, year: movie.year, profile: tmdb_profile(movie)),
           %{"id" => id} <-
             Enum.find(results, &year_matches?(&1["release_date"], movie.year)) do
        to_string(id)
      else
        _ -> nil
      end
    else
      nil
    end
  end

  # GIndex-sourced movies hit TMDB under a dedicated profile so their quota
  # stays isolated from the default (Xtream) ingestion path.
  defp tmdb_profile(%Movie{gindex_path: path}) when is_binary(path) and path != "",
    do: :gindex

  defp tmdb_profile(_movie), do: :default

  # No year on our side → trust the first hit. Otherwise require ±1 year.
  defp year_matches?(_release_date, nil), do: true
  defp year_matches?(nil, _year), do: false
  defp year_matches?("", _year), do: false

  defp year_matches?(release_date, year) when is_binary(release_date) and is_integer(year) do
    case Integer.parse(release_date) do
      {result_year, _} -> abs(result_year - year) <= 1
      :error -> false
    end
  end

  defp year_matches?(_, _), do: false

  defp maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)
       when is_binary(tmdb_id) and tmdb_id != "" do
    if needs_tmdb_enrichment?(movie, xtream_attrs) do
      fetch_from_tmdb(tmdb_id, tmdb_profile(movie))
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
      (is_nil(xtream_attrs[:cast]) and Enum.empty?(movie.credits || [])) or
      (is_nil(xtream_attrs[:director]) and Enum.empty?(movie.credits || []))
  end

  defp missing_extended_info?(movie) do
    is_nil(movie.content_rating) and is_nil(movie.tagline) and not Movie.has_images?(movie)
  end

  defp missing_field?(xtream_val, movie_val), do: is_nil(xtream_val) and is_nil(movie_val)

  defp fetch_from_tmdb(tmdb_id, profile) do
    case TmdbClient.get_movie(tmdb_id, profile: profile) do
      {:ok, data} ->
        TmdbClient.parse_movie_response(data)

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[IPTV] TMDB API failed for tmdb_id #{tmdb_id} (profile=#{profile})",
          reason: inspect(reason)
        )

        %{}

      _ ->
        %{}
    end
  end

  defp update_movie(movie, attrs) when attrs == %{}, do: {:ok, movie}

  defp update_movie(movie, attrs) do
    # _backdrop_urls and _image_urls come from TmdbClient.parse_movie_response/1
    # but are not Movie schema fields — persist them as MovieAsset rows after
    # the base update succeeds, otherwise cast/3 would silently drop them.
    {backdrops, attrs} = Map.pop(attrs, :_backdrop_urls, [])
    {images, attrs} = Map.pop(attrs, :_image_urls, [])

    with {:ok, updated} <- movie |> Movie.changeset(attrs) |> Repo.update() do
      persist_movie_assets(updated.id, "backdrop", backdrops)
      persist_movie_assets(updated.id, "image", images)
      {:ok, updated}
    end
  end

  @doc false
  def persist_movie_assets(_movie_id, _type, nil), do: :ok
  def persist_movie_assets(_movie_id, _type, []), do: :ok

  def persist_movie_assets(movie_id, type, urls) when is_list(urls) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      urls
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.with_index()
      |> Enum.map(fn {url, idx} ->
        %{
          movie_id: movie_id,
          asset_type: type,
          url: url,
          position: idx,
          inserted_at: now,
          updated_at: now
        }
      end)

    case entries do
      [] ->
        :ok

      _ ->
        # Idempotent insert — unique index on (movie_id, asset_type, url)
        # (see migration 20260417221822) means re-enriching the same movie
        # is a no-op instead of a delete+insert cycle.
        Repo.insert_all(MovieAsset, entries,
          on_conflict: :nothing,
          conflict_target: [:movie_id, :asset_type, :url]
        )
    end

    :ok
  end

  defp parse_vod_info(info, movie_data) when is_map(info) do
    %{}
    |> maybe_put(:title, info["name"])
    |> maybe_put(:plot, info["plot"] || info["description"])
    |> maybe_put(:duration_secs, parse_duration_secs(info["duration_secs"] || info["duration"]))
    |> maybe_put(:rating, parse_decimal(info["rating"]))
    |> maybe_put(:year, parse_integer(info["releasedate"] || info["release_date"]))
    |> maybe_put(:tmdb_id, to_string_or_nil(info["tmdb_id"]))
    |> maybe_put(:imdb_id, info["kinopoisk_url"])
    |> maybe_put(:youtube_trailer, info["youtube_trailer"])
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

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_), do: nil
end
