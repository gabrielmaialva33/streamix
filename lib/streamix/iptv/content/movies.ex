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
  alias Streamix.Iptv.Content.SourceEquivalence
  alias Streamix.Iptv.Content.VariantCards
  alias Streamix.Repo

  @summary_preloads [:genres]
  @search_result_preloads [:assets, :genres]
  @detail_preloads [:assets, :genres, credits: :person]
  @variant_preloads [:provider, :categories]
  @visible_dedupe_min_window 120

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
    * `:dedupe` - Collapse provider variants into one browse card (default: false)
  """
  @spec list(integer(), keyword()) :: [Movie.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)
    dedupe? = Keyword.get(opts, :dedupe, false)

    provider_id
    |> Queries.filtered_provider(opts)
    |> maybe_dedupe_variants(dedupe?)
    |> Queries.sorted(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> Queries.select_card_fields()
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
  Lists movies across all providers visible to a user.

  This powers the aggregate browse mode (`provider=all`): the grid shows one
  canonical card per movie while the detail page exposes provider variants.
  """
  @spec list_visible(integer(), keyword()) :: [Movie.t()]
  def list_visible(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort)
    dedupe? = Keyword.get(opts, :dedupe, true)

    if dedupe? do
      list_visible_deduped(user_id, opts, limit, offset, sort)
    else
      list_visible_candidates(user_id, opts, sort, limit, offset)
    end
  end

  defp list_visible_deduped(user_id, opts, limit, offset, sort) do
    target_count = offset + limit
    batch_limit = max(limit * 4, @visible_dedupe_min_window)

    user_id
    |> collect_visible_cards(opts, sort, batch_limit, 0, target_count, VariantCards.new())
    |> sort_visible_cards(sort)
    |> Enum.slice(offset, limit)
  end

  defp collect_visible_cards(
         user_id,
         opts,
         sort,
         batch_limit,
         batch_offset,
         target_count,
         clusters
       ) do
    batch = list_visible_candidates(user_id, opts, sort, batch_limit, batch_offset)
    clusters = Enum.reduce(batch, clusters, &VariantCards.add(&2, &1))

    if VariantCards.count(clusters) >= target_count or length(batch) < batch_limit do
      VariantCards.cards(clusters)
    else
      collect_visible_cards(
        user_id,
        opts,
        sort,
        batch_limit,
        batch_offset + batch_limit,
        target_count,
        clusters
      )
    end
  end

  defp list_visible_candidates(user_id, opts, sort, limit, offset) do
    user_id
    |> Queries.filtered_visible(opts)
    |> Queries.sorted(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> Queries.select_card_fields()
    |> preload(^@summary_preloads)
    |> Repo.all()
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
  Lists visible movie cards for ranked IDs while preserving the requested order.

  This is the hydration boundary for external ranking systems such as Qdrant:
  stale, inaccessible, inactive-provider, and adult-filtered IDs are omitted.
  """
  @spec list_visible_by_ids(integer(), [integer()], keyword()) :: [Movie.t()]
  def list_visible_by_ids(_user_id, [], _opts), do: []

  def list_visible_by_ids(user_id, ids, opts) when is_list(ids) do
    ranked_ids = Enum.uniq(ids)

    movies_by_id =
      user_id
      |> Queries.filtered_visible(opts)
      |> where([movie], movie.id in ^ranked_ids)
      |> Queries.select_card_fields()
      |> preload(^@summary_preloads)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ranked_ids, fn id ->
      case Map.fetch(movies_by_id, id) do
        {:ok, movie} -> [movie]
        :error -> []
      end
    end)
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
    |> preload(^[:provider | @detail_preloads])
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

  Provider variants of the same title are collapsed into one canonical
  card (see `Streamix.Iptv.Content.VariantCards`), so duplicates never
  crowd distinct titles out of the result page.
  """
  @spec search(integer(), String.t(), keyword()) :: [Movie.t()]
  def search(user_id, query, opts \\ []) do
    list_visible(user_id,
      search: query,
      sort: "rating_desc",
      limit: Keyword.get(opts, :limit, 24),
      offset: Keyword.get(opts, :offset, 0),
      show_adult: Keyword.get(opts, :show_adult, false)
    )
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

  @doc """
  Lists all visible provider variants for the same canonical movie.

  This powers the detail-page version picker: the browse grid can show a
  single canonical card while the detail page still exposes provider/category
  variants such as 4K, HDR, dubbed, or alternate upstream copies.
  """
  @spec list_variants(Movie.t(), integer(), keyword()) :: [Movie.t()]
  def list_variants(%Movie{} = movie, user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    candidate_limit = max(limit * 4, 48)
    tmdb_id = blank_to_nil(movie.tmdb_id)
    normalized_title = VariantCards.normalize_title(movie.title || movie.name)
    search_title = variant_search_title(movie)

    linked_variants =
      movie.catalog_item_id
      |> SourceEquivalence.catalog_item_ids()
      |> variants_by_catalog_item_ids(user_id, limit)

    tmdb_variants =
      case tmdb_id do
        nil -> []
        tmdb_id -> variants_by_tmdb_id(tmdb_id, user_id, limit)
      end

    title_variants =
      case {normalized_title, search_title,
            VariantCards.reliable_title?(movie.title || movie.name)} do
        {"", _, _} ->
          []

        {_, "", _} ->
          []

        {_, _, false} ->
          []

        {_, _, true} ->
          variants_by_title(search_title, normalized_title, user_id, candidate_limit)
      end

    (linked_variants ++ tmdb_variants ++ title_variants)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn movie -> {-movie.id, provider_sort_name(movie)} end)
    |> Enum.take(limit)
  end

  defp variants_by_tmdb_id(tmdb_id, user_id, limit) do
    Movie
    |> Access.visible_to_user(user_id)
    |> where([m, _p], m.tmdb_id == ^tmdb_id)
    |> order_by([m, p], desc: m.id, asc: p.name)
    |> limit(^limit)
    |> preload(^@variant_preloads)
    |> Repo.all()
  end

  defp variants_by_catalog_item_ids([], _user_id, _limit), do: []

  defp variants_by_catalog_item_ids(catalog_item_ids, user_id, limit) do
    Movie
    |> Access.visible_to_user(user_id)
    |> where([movie, _provider], movie.catalog_item_id in ^catalog_item_ids)
    |> order_by([movie, provider], desc: movie.id, asc: provider.name)
    |> limit(^limit)
    |> preload(^@variant_preloads)
    |> Repo.all()
  end

  defp variants_by_title(search_title, normalized_title, user_id, limit) do
    Movie
    |> Access.visible_to_user(user_id)
    |> where(
      [m, _p],
      fragment("? % ?", ^search_title, m.name) or
        fragment("? % coalesce(?, '')", ^search_title, m.title)
    )
    |> order_by(
      [m, p],
      desc:
        fragment(
          "GREATEST(similarity(?, ?), similarity(?, coalesce(?, '')))",
          ^search_title,
          m.name,
          ^search_title,
          m.title
        ),
      desc: m.id,
      asc: p.name
    )
    |> limit(^limit)
    |> preload(^@variant_preloads)
    |> Repo.all()
    |> Enum.filter(&(VariantCards.normalize_title(&1.title || &1.name) == normalized_title))
  end

  defp provider_sort_name(%{provider: %{name: name}}) when is_binary(name), do: name
  defp provider_sort_name(_), do: ""

  defp maybe_dedupe_variants(query, true), do: Queries.dedupe_variants(query)
  defp maybe_dedupe_variants(query, _dedupe), do: query

  defp variant_search_title(%Movie{} = movie) do
    movie.title
    |> blank_to_nil()
    |> Kernel.||(movie.name)
    |> VariantCards.strip_variant_terms()
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp sort_visible_cards(movies, "rating_desc") do
    Enum.sort_by(movies, fn movie ->
      {desc_numeric(movie.rating), desc_year(movie.year), movie.name || "", -movie.id}
    end)
  end

  defp sort_visible_cards(movies, "created_desc") do
    Enum.sort_by(movies, fn movie ->
      {desc_datetime(movie.inserted_at), -movie.id}
    end)
  end

  defp sort_visible_cards(movies, "name_asc") do
    Enum.sort_by(movies, fn movie -> {movie.name || "", -movie.id} end)
  end

  defp sort_visible_cards(movies, _sort) do
    Enum.sort_by(movies, fn movie -> {desc_year(movie.year), movie.name || "", -movie.id} end)
  end

  defp desc_numeric(%Decimal{} = value), do: -Decimal.to_float(value)
  defp desc_numeric(value) when is_number(value), do: -value
  defp desc_numeric(_value), do: 1_000_000_000

  defp desc_year(year) when is_integer(year), do: -year
  defp desc_year(_year), do: 1_000_000_000

  defp desc_datetime(%DateTime{} = datetime), do: -DateTime.to_unix(datetime, :microsecond)

  defp desc_datetime(%NaiveDateTime{} = datetime),
    do: -NaiveDateTime.diff(datetime, ~N[1970-01-01 00:00:00], :microsecond)

  defp desc_datetime(_datetime), do: 1_000_000_000_000_000

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
