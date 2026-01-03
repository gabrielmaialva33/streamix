defmodule Streamix.Iptv.SeriesOps do
  @moduledoc """
  Series and episode operations.

  Provides listing, searching, and retrieval of TV series and episodes
  with proper access control based on provider visibility.
  Also handles fetching detailed info from TMDB.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Access, AdultFilter, Episode, Provider, Season, Series, Sync, TmdbClient}
  alias Streamix.Repo

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
      |> where([s], s.content_type == "anime" and not is_nil(s.gindex_path))
      |> order_by(asc: :name)

    query =
      if search && search != "" do
        where(query, [s], ilike(s.name, ^"%#{search}%") or ilike(s.title, ^"%#{search}%"))
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
    |> where([s], s.content_type == "anime" and not is_nil(s.gindex_path))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex anime by ID with its releases (seasons) and episodes.
  Returns nil if not a GIndex anime.
  """
  @spec get_gindex_anime_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_anime_with_seasons(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> where([s], s.content_type == "anime" and not is_nil(s.gindex_path))
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
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
      |> where([s], s.content_type != "anime" or is_nil(s.content_type))
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        where(query, [s], ilike(s.name, ^"%#{search}%") or ilike(s.title, ^"%#{search}%"))
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
    |> where([s], s.content_type != "anime" or is_nil(s.content_type))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a GIndex series by ID with its seasons and episodes.
  Returns nil if not a GIndex series.
  """
  @spec get_gindex_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_with_seasons(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> where([s], not is_nil(s.gindex_path))
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
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

    query =
      Series
      |> where(provider_id: ^provider_id)
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        where(query, [s], ilike(s.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [s], sc in "series_categories",
          on: sc.series_id == s.id and sc.category_id == ^category_id
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
    |> Repo.all()
  end

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
    |> Repo.all()
  end

  @doc """
  Gets a series from public providers only (for guests).
  """
  @spec get_public(integer()) :: Series.t() | nil
  def get_public(series_id) do
    Series
    |> Access.public_only(series_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a series with its seasons and episodes preloaded.
  """
  @spec get_with_seasons(integer()) :: Series.t() | nil
  def get_with_seasons(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a series with its seasons and episodes preloaded. Raises if not found.
  """
  @spec get_with_seasons!(integer()) :: Series.t()
  def get_with_seasons!(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
    |> preload(:provider)
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
    needs_sync = series.episode_count == 0 or is_nil(series.tmdb_id) or series.tmdb_id == ""

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
    |> preload(season: [series: :provider])
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

  # =============================================================================
  # Search
  # =============================================================================

  @doc """
  Searches series across all visible providers (global + public + user's private).
  """
  @spec search(integer(), String.t(), keyword()) :: [Series.t()]
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Series
    |> Access.visible_to_user(user_id)
    |> where([s, _p], ilike(s.name, ^"%#{query}%") or ilike(s.title, ^"%#{query}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches series in public providers only (for guests).
  """
  @spec search_public(String.t(), keyword()) :: [Series.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Series
    |> Access.public_providers()
    |> where([s, _p], ilike(s.name, ^"%#{query}%") or ilike(s.title, ^"%#{query}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
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
    missing_cast = is_nil(series.cast)
    missing_director = is_nil(series.director)

    # Also check for extended metadata from TMDB
    missing_extended =
      is_nil(series.content_rating) and is_nil(series.tagline) and
        (is_nil(series.images) or series.images == [])

    missing_plot or missing_cast or missing_director or missing_extended
  end

  defp update_series(series, attrs) when attrs == %{}, do: {:ok, series}

  defp update_series(series, attrs) do
    series
    |> Series.changeset(attrs)
    |> Repo.update()
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
end
