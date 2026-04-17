defmodule Streamix.Iptv.SeriesOps do
  @moduledoc """
  Series and episode operations.

  Provides listing, searching, and retrieval of TV series and episodes
  with proper access control based on provider visibility.
  Also handles fetching detailed info from TMDB.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.{
    Access,
    AdultFilter,
    Episode,
    Provider,
    Season,
    Series,
    SeriesAsset,
    Sync,
    TmdbClient
  }
  alias Streamix.Repo

  @summary_preloads [:genres]
  @search_result_preloads [:assets, :genres]
  @detail_preloads [:assets, :genres, credits: :person]

  # =============================================================================
  # GIndex Anime Functions
  # =============================================================================

  @doc """
  Lists GIndex animes (content_type = "anime" with gindex_path set).

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for anime name
  """
  @spec list_gindex_animes(keyword()) :: [Series.t()]
  def list_gindex_animes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)

    query =
      Series
      |> where([s], not is_nil(s.gindex_path))
      |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
      |> order_by(asc: :name)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [s], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts GIndex animes.
  """
  @spec count_gindex_animes() :: integer()
  def count_gindex_animes do
    Series
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex anime by ID with its releases (seasons) and episodes.
  Returns nil if not a GIndex anime.
  """
  @spec get_gindex_anime_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_anime_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], ilike(s.gindex_path, "%anime%") or ilike(s.gindex_path, "%Anime%"))
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(:provider)
    |> Repo.one()
  end

  # =============================================================================
  # GIndex Series Functions
  # =============================================================================

  @doc """
  Lists GIndex series (series with gindex_path set, excluding animes).

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for series name
  """
  @spec list_gindex(keyword()) :: [Series.t()]
  def list_gindex(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)

    query =
      Series
      |> where([s], not is_nil(s.gindex_path))
      |> where([s], not ilike(s.gindex_path, "%anime%") and not ilike(s.gindex_path, "%Anime%"))
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [s], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts GIndex series (excluding animes).
  """
  @spec count_gindex() :: integer()
  def count_gindex do
    Series
    |> where([s], not is_nil(s.gindex_path))
    |> where([s], not ilike(s.gindex_path, "%anime%") and not ilike(s.gindex_path, "%Anime%"))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex series by ID with its seasons and episodes.
  Returns nil if not a GIndex series.
  """
  @spec get_gindex_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> where([s], not is_nil(s.gindex_path))
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(:provider)
    |> Repo.one()
  end

  # =============================================================================
  # Series Listing
  # =============================================================================

  @doc """
  Lists series for a specific provider with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for series name
    * `:category_id` - Filter by category ID
    * `:show_adult` - Include adult content (default: false)
  """
  @spec list(integer(), keyword()) :: [Series.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)
    sort = Keyword.get(opts, :sort)

    query =
      Series
      |> where(provider_id: ^provider_id)
      |> apply_series_sort(sort)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [s], ilike(s.name, ^"%#{escaped}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [s], ic in "item_categories",
          on: ic.catalog_item_id == s.catalog_item_id and ic.category_id == ^category_id
        )
      else
        query
      end

    # Filter adult content unless user opts in
    query =
      if show_adult do
        query
      else
        AdultFilter.exclude_adult_series(query, provider_id)
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  # Sort order for public series lists.
  # Supported: rating_desc | created_desc | year_desc | name_asc.
  # Default (nil/unknown): desc year, asc name.
  defp apply_series_sort(query, "rating_desc"),
    do: order_by(query, [s], [fragment("? DESC NULLS LAST", s.rating), desc: s.year, asc: s.name])

  defp apply_series_sort(query, "created_desc"),
    do: order_by(query, [s], desc: s.inserted_at)

  defp apply_series_sort(query, "year_desc"),
    do: order_by(query, [s], [fragment("? DESC NULLS LAST", s.year), asc: s.name])

  defp apply_series_sort(query, "name_asc"), do: order_by(query, [s], asc: s.name)
  defp apply_series_sort(query, _), do: order_by(query, [s], desc: s.year, asc: s.name)

  @doc """
  Lists featured series from public/global providers for public display.
  """
  @spec list_public(keyword()) :: [Series.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Series
    |> Access.public_providers()
    |> where([s, _p], not is_nil(s.cover))
    |> order_by([s], desc: s.rating, desc: s.year, asc: s.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Counts series for a provider.
  """
  @spec count(integer()) :: integer()
  def count(provider_id) do
    Series
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  # =============================================================================
  # Series Retrieval
  # =============================================================================

  @doc """
  Gets a series by ID. Raises if not found.
  """
  @spec get!(integer()) :: Series.t()
  def get!(id), do: Repo.get!(Series, id)

  @doc """
  Gets a series by ID. Returns nil if not found.
  """
  @spec get(integer()) :: Series.t() | nil
  def get(id), do: Repo.get(Series, id)

  @doc """
  Gets multiple series by their IDs.
  Returns series in arbitrary order.
  """
  @spec get_by_ids([integer()]) :: [Series.t()]
  def get_by_ids([]), do: []

  def get_by_ids(ids) when is_list(ids) do
    from(s in Series, where: s.id in ^ids)
    |> preload(^@search_result_preloads)
    |> Repo.all()
  end

  @doc """
  Gets a series from public providers only (for guests).
  """
  @spec get_public(integer()) :: Series.t() | nil
  def get_public(series_id) do
    Series
    |> Access.public_only(series_id)
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one()
  end

  # Hide season 0 — the Xtream / TMDB feeds use it for "Specials" (trailers,
  # behind-the-scenes, interviews). It confuses the UI since end users
  # expect "Temporada 1" first. Rows stay in the DB for future use.
  defp public_seasons_query do
    from(s in Season, where: s.season_number > 0, order_by: s.season_number)
  end

  defp public_episodes_query do
    from(e in Episode, order_by: e.episode_num)
  end

  @doc """
  Gets a series with its seasons and episodes preloaded.
  Season 0 ("Specials") is hidden — see `public_seasons_query/0`.
  """
  @spec get_with_seasons(integer()) :: Series.t() | nil
  def get_with_seasons(id) do
    Series
    |> where(id: ^id)
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one()
  end

  @doc """
  Gets a series with its seasons and episodes preloaded. Raises if not found.
  Season 0 ("Specials") is hidden — see `public_seasons_query/0`.
  """
  @spec get_with_seasons!(integer()) :: Series.t()
  def get_with_seasons!(id) do
    Series
    |> where(id: ^id)
    |> preload(seasons: ^{public_seasons_query(), episodes: public_episodes_query()})
    |> preload(^[:provider | @detail_preloads])
    |> Repo.one!()
  end

  @doc """
  Gets a series with seasons/episodes, syncing on-demand if needed.
  Syncs from the API if the series has no episodes or is missing tmdb_id.
  Returns {:ok, series} or {:error, reason}.
  """
  @spec get_with_sync!(integer()) :: {:ok, Series.t()}
  def get_with_sync!(id) do
    series = get!(id)

    # Sync if no episodes yet OR missing tmdb_id (for TMDB enrichment)
    episode_count = count_episodes_for_series(series.id)
    needs_sync = episode_count == 0 or is_nil(series.tmdb_id) or series.tmdb_id == ""

    if needs_sync do
      case Sync.sync_series_details(series) do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
      end
    end

    # Return fresh data with preloads
    {:ok, get_with_seasons!(id)}
  end

  # =============================================================================
  # Episode Retrieval
  # =============================================================================

  @doc """
  Gets an episode by ID. Raises if not found.
  """
  @spec get_episode!(integer()) :: Episode.t()
  def get_episode!(id), do: Repo.get!(Episode, id)

  @doc """
  Gets an episode by ID. Returns nil if not found.
  """
  @spec get_episode(integer()) :: Episode.t() | nil
  def get_episode(id), do: Repo.get(Episode, id)

  @doc """
  Gets an episode for stream resolution with only season/series/provider context loaded.
  """
  @spec get_episode_for_stream(integer()) :: Episode.t() | nil
  def get_episode_for_stream(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode owned by a specific user.
  """
  @spec get_user_episode(integer(), integer()) :: Episode.t() | nil
  def get_user_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, s, sr, p], e.id == ^episode_id and p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  @spec get_playable_episode(integer(), integer()) :: Episode.t() | nil
  def get_playable_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([e, s, sr, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode from public providers only (for guests).
  """
  @spec get_public_episode(integer()) :: Episode.t() | nil
  def get_public_episode(episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([e, s, sr, p], p.visibility in [:global, :public])
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode with its full context (season -> series -> provider).
  Raises if not found.
  """
  @spec get_episode_with_context!(integer()) :: Episode.t()
  def get_episode_with_context!(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: [:provider, :assets]])
    |> Repo.one!()
  end

  @doc """
  Lists all episodes for a season, ordered by episode number.
  """
  @spec list_season_episodes(integer()) :: [Episode.t()]
  def list_season_episodes(season_id) do
    Episode
    |> where(season_id: ^season_id)
    |> order_by(:episode_num)
    |> Repo.all()
  end

  @doc """
  Gets the next episode after the given episode.

  First tries to find the next episode in the same season.
  If not found, tries to find the first episode of the next season.
  Returns nil if there's no next episode.
  """
  @spec get_next_episode(integer()) :: Episode.t() | nil
  def get_next_episode(episode_id) do
    episode = get_episode(episode_id)
    if episode, do: find_next_episode(episode), else: nil
  end

  defp find_next_episode(episode) do
    # Load season context if not loaded
    episode = Repo.preload(episode, season: :series)
    season = episode.season

    # Try next episode in same season
    next_in_season =
      Episode
      |> where([e], e.season_id == ^season.id)
      |> where([e], e.episode_num > ^episode.episode_num)
      |> order_by([e], asc: e.episode_num)
      |> limit(1)
      |> preload(season: [series: :provider])
      |> Repo.one()

    if next_in_season do
      next_in_season
    else
      # Try first episode of next season
      next_season =
        Season
        |> where([s], s.series_id == ^season.series_id)
        |> where([s], s.season_number > ^season.season_number)
        |> order_by([s], asc: s.season_number)
        |> limit(1)
        |> Repo.one()

      if next_season do
        Episode
        |> where([e], e.season_id == ^next_season.id)
        |> order_by([e], asc: e.episode_num)
        |> limit(1)
        |> preload(season: [series: :provider])
        |> Repo.one()
      else
        nil
      end
    end
  end

  # =============================================================================
  # Search
  # =============================================================================

  @doc """
  Searches series across all visible providers (global + public + user's private).
  """
  @spec search(integer(), String.t(), keyword()) :: [Series.t()]
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    escaped = Helpers.escape_like(query)

    Series
    |> Access.visible_to_user(user_id)
    |> where([s, _p], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  @doc """
  Searches series in public providers only (for guests).
  """
  @spec search_public(String.t(), keyword()) :: [Series.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    escaped = Helpers.escape_like(query)

    Series
    |> Access.public_providers()
    |> where([s, _p], ilike(s.name, ^"%#{escaped}%") or ilike(s.title, ^"%#{escaped}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> preload(^@summary_preloads)
    |> Repo.all()
  end

  # =============================================================================
  # TMDB Info Fetching
  # =============================================================================

  @doc """
  Fetches detailed series info from TMDB if missing key data.
  Returns {:ok, updated_series} or {:error, reason}.
  """
  @spec fetch_info(Series.t()) :: {:ok, Series.t()} | {:error, term()}
  def fetch_info(%Series{} = series) do
    series = Repo.preload(series, @detail_preloads)
    tmdb_id = series.tmdb_id

    if needs_tmdb_enrichment?(series) and is_binary(tmdb_id) and tmdb_id != "" do
      case TmdbClient.get_series(tmdb_id) do
        {:ok, data} ->
          attrs = TmdbClient.parse_series_response(data)
          update_series(series, attrs)

        {:error, _reason} ->
          {:ok, series}
      end
    else
      {:ok, series}
    end
  end

  @doc """
  Fetches detailed episode info from TMDB if not already enriched.
  Uses the series tmdb_id and season number to fetch the entire season,
  then matches by episode number.
  Returns {:ok, updated_episode} or {:error, reason}.
  """
  @spec fetch_episode_info(Episode.t()) :: {:ok, Episode.t()} | {:error, term()}
  def fetch_episode_info(%Episode{} = episode) do
    episode = Repo.preload(episode, season: :series)
    series = episode.season.series
    tmdb_id = series.tmdb_id
    season_number = episode.season.season_number

    if needs_episode_tmdb_enrichment?(episode) and is_binary(tmdb_id) and tmdb_id != "" do
      fetch_and_update_episode(episode, tmdb_id, season_number)
    else
      {:ok, episode}
    end
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp needs_tmdb_enrichment?(series) do
    missing_plot = is_nil(series.plot)
    credits = series.credits || []
    missing_cast = Enum.empty?(Enum.filter(credits, &(&1.role == "cast")))
    missing_director = Enum.empty?(Enum.filter(credits, &(&1.role == "director")))

    # Also check for extended metadata from TMDB
    missing_extended =
      is_nil(series.content_rating) and is_nil(series.tagline) and
        not Series.has_images?(series)

    missing_plot or missing_cast or missing_director or missing_extended
  end

  defp update_series(series, attrs) when attrs == %{}, do: {:ok, series}

  defp update_series(series, attrs) do
    # Same pattern as Movies.update_movie/2: _backdrop_urls / _image_urls
    # from TmdbClient.parse_series_response/1 aren't Series schema fields,
    # so persist them as SeriesAsset rows after the base update.
    {backdrops, attrs} = Map.pop(attrs, :_backdrop_urls, [])
    {images, attrs} = Map.pop(attrs, :_image_urls, [])

    with {:ok, updated} <- series |> Series.changeset(attrs) |> Repo.update() do
      persist_series_assets(updated.id, "backdrop", backdrops)
      persist_series_assets(updated.id, "image", images)
      {:ok, updated}
    end
  end

  @doc false
  def persist_series_assets(_series_id, _type, nil), do: :ok
  def persist_series_assets(_series_id, _type, []), do: :ok

  def persist_series_assets(series_id, type, urls) when is_list(urls) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      urls
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.with_index()
      |> Enum.map(fn {url, idx} ->
        %{
          series_id: series_id,
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
        # See Streamix.Iptv.Movies.persist_movie_assets/3 for the rationale.
        Repo.insert_all(SeriesAsset, entries,
          on_conflict: :nothing,
          conflict_target: [:series_id, :asset_type, :url]
        )
    end

    :ok
  end

  defp needs_episode_tmdb_enrichment?(episode) do
    not episode.tmdb_enriched
  end

  defp fetch_and_update_episode(episode, tmdb_id, season_number) do
    case TmdbClient.get_season(tmdb_id, season_number) do
      {:ok, data} ->
        data
        |> TmdbClient.parse_season_episodes()
        |> Map.get(episode.episode_num)
        |> case do
          nil -> {:ok, episode}
          attrs -> update_episode(episode, attrs)
        end

      {:error, _reason} ->
        {:ok, episode}
    end
  end

  defp update_episode(episode, attrs) when attrs == %{}, do: {:ok, episode}

  defp update_episode(episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Counts total episodes for a series by querying through seasons.
  """
  @spec count_episodes_for_series(integer()) :: integer()
  def count_episodes_for_series(series_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> where([_e, s], s.series_id == ^series_id)
    |> Repo.aggregate(:count)
  end
end
