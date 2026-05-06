defmodule Streamix.Iptv.Movies do
  @moduledoc """
  Movie operations.

  Provides listing, searching, and retrieval of VOD movies
  with proper access control based on provider visibility.
  Also handles fetching detailed movie info from external APIs.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{
    Access,
    Content,
    Movie
  }

  alias Streamix.Iptv.Content.Movies.{Enrichment, Queries}
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
    sort = Keyword.get(opts, :sort)

    provider_id
    |> Queries.filtered_provider(opts)
    |> Queries.sorted(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

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
    Content.GindexMovies.list(opts)
  end

  @doc """
  Counts GIndex movies.
  """
  @spec count_gindex() :: integer()
  def count_gindex do
    Content.GindexMovies.count()
  end

  @doc """
  Lists featured movies from public/global providers for public display.
  Orders by rating and recency.
  """
  @spec list_public(keyword()) :: [Movie.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    limit
    |> Queries.public_list()
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Counts movies for a provider. Accepts the same `opts` as `list/2`
  (`:category_id`, `:search`, `:year`, `:show_adult`) so paginated
  endpoints can report the actual filtered total. When a category
  filter is present we use `count(m.id, :distinct)` so movies sitting
  in multiple categories don't inflate the count.
  """
  @spec count(integer(), keyword()) :: integer()
  def count(provider_id, opts \\ []) do
    provider_id
    |> Queries.count_provider(opts)
    |> Repo.one()
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

    user_id
    |> Queries.visible_search(query, limit)
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

    query
    |> Queries.public_search(limit)
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
    xtream_attrs = Enrichment.fetch_xtream_attrs(movie)

    # Step 2: Resolve a tmdb_id. Prefer what Xtream returned, then what we
    # already have stored, and finally fall back to a name+year search on
    # TMDB so titles from providers that don't ship tmdb_id still get
    # enriched on their first enrichment run.
    resolved_tmdb_id =
      xtream_attrs[:tmdb_id] || movie.tmdb_id || Enrichment.resolve_movie_tmdb_id(movie)

    # Persist the resolved id so the next enrichment skips the search.
    xtream_attrs =
      if is_binary(resolved_tmdb_id) and resolved_tmdb_id != "" and
           is_nil(xtream_attrs[:tmdb_id]) do
        Map.put(xtream_attrs, :tmdb_id, resolved_tmdb_id)
      else
        xtream_attrs
      end

    # Step 3: Fetch from TMDB if we're still missing key data
    tmdb_attrs = Enrichment.maybe_fetch_from_tmdb(movie, xtream_attrs, resolved_tmdb_id)

    # Step 4: Merge attrs (TMDB fills in what Xtream didn't provide)
    final_attrs = Map.merge(tmdb_attrs, xtream_attrs)

    case Enrichment.update_movie(movie, final_attrs) do
      {:ok, updated} -> {:ok, Repo.preload(updated, @detail_preloads, force: true)}
      error -> error
    end
  end

  @doc false
  defdelegate persist_movie_assets(movie_id, type, urls), to: Enrichment
end
