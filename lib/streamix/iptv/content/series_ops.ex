defmodule Streamix.Iptv.SeriesOps do
  @moduledoc """
  Series and episode operations.

  Provides listing, searching, and retrieval of TV series and episodes
  with proper access control based on provider visibility.
  Also handles fetching detailed info from TMDB.
  """

  alias Streamix.Iptv.Content.SeriesOps.{Enrichment, Queries}

  alias Streamix.Iptv.{
    Content,
    Episode,
    Series,
    Sync
  }

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
    Content.GindexSeries.list_animes(opts)
  end

  @doc """
  Counts GIndex animes.
  """
  @spec count_gindex_animes() :: integer()
  def count_gindex_animes do
    Content.GindexSeries.count_animes()
  end

  @doc """
  Gets a GIndex anime by ID with its releases (seasons) and episodes.
  Returns nil if not a GIndex anime.
  """
  @spec get_gindex_anime_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_anime_with_seasons(id) do
    Content.GindexSeries.get_anime_with_seasons(id)
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
    Content.GindexSeries.list(opts)
  end

  @doc """
  Counts GIndex series (excluding animes).
  """
  @spec count_gindex() :: integer()
  def count_gindex do
    Content.GindexSeries.count()
  end

  @doc """
  Gets a GIndex series by ID with its seasons and episodes.
  Returns nil if not a GIndex series.
  """
  @spec get_gindex_with_seasons(integer()) :: Series.t() | nil
  def get_gindex_with_seasons(id) do
    Content.GindexSeries.get_with_seasons(id)
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
    Queries.list(provider_id, opts)
  end

  @doc """
  Lists featured series from public/global providers for public display.
  """
  @spec list_public(keyword()) :: [Series.t()]
  def list_public(opts \\ []) do
    Queries.list_public(opts)
  end

  @doc """
  Counts series for a provider. Accepts the same `opts` as `list/2`
  (`:category_id`, `:search`, `:show_adult`) so paginated endpoints
  can report the actual filtered total.
  """
  @spec count(integer(), keyword()) :: integer()
  def count(provider_id, opts \\ []) do
    Queries.count(provider_id, opts)
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
    Queries.get_by_ids(ids)
  end

  @doc """
  Gets a series from public providers only (for guests).
  """
  @spec get_public(integer()) :: Series.t() | nil
  def get_public(series_id) do
    Queries.get_public(series_id)
  end

  @doc """
  Gets a series with its seasons and episodes preloaded.
  Season 0 ("Specials") is hidden by the query helper.
  """
  @spec get_with_seasons(integer()) :: Series.t() | nil
  def get_with_seasons(id) do
    Queries.get_with_seasons(id)
  end

  @doc """
  Gets a series with its seasons and episodes preloaded. Raises if not found.
  Season 0 ("Specials") is hidden by the query helper.
  """
  @spec get_with_seasons!(integer()) :: Series.t()
  def get_with_seasons!(id) do
    Queries.get_with_seasons!(id)
  end

  @doc """
  Gets a series with seasons/episodes, syncing on-demand if needed.
  Syncs from the API if the series has no episodes or is missing tmdb_id.
  Returns {:ok, series} or {:error, reason}.
  """
  @spec get_with_sync!(integer()) :: {:ok, Series.t()}
  def get_with_sync!(id) do
    series = get!(id)

    episode_count = count_episodes_for_series(series.id)
    needs_sync = episode_count == 0 or is_nil(series.tmdb_id) or series.tmdb_id == ""

    if needs_sync and upstream_available?(series.provider_id) do
      case Sync.sync_series_details(series) do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
      end
    end

    {:ok, get_with_seasons!(id)}
  end

  defp upstream_available?(provider_id) when is_integer(provider_id) do
    alias Streamix.Iptv.XtreamCircuitBreaker
    XtreamCircuitBreaker.allow_request?(provider_id)
  rescue
    _ -> true
  end

  defp upstream_available?(_), do: true

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
    Queries.get_episode_for_stream(id)
  end

  @doc """
  Gets an episode owned by a specific user.
  """
  @spec get_user_episode(integer(), integer()) :: Episode.t() | nil
  def get_user_episode(user_id, episode_id) do
    Queries.get_user_episode(user_id, episode_id)
  end

  @doc """
  Gets an episode if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  @spec get_playable_episode(integer(), integer()) :: Episode.t() | nil
  def get_playable_episode(user_id, episode_id) do
    Queries.get_playable_episode(user_id, episode_id)
  end

  @doc """
  Gets an episode from public providers only (for guests).
  """
  @spec get_public_episode(integer()) :: Episode.t() | nil
  def get_public_episode(episode_id) do
    Queries.get_public_episode(episode_id)
  end

  @doc """
  Gets an episode with its full context (season -> series -> provider).
  Raises if not found.
  """
  @spec get_episode_with_context!(integer()) :: Episode.t()
  def get_episode_with_context!(id) do
    Queries.get_episode_with_context!(id)
  end

  @doc """
  Lists all episodes for a season, ordered by episode number.
  """
  @spec list_season_episodes(integer()) :: [Episode.t()]
  def list_season_episodes(season_id) do
    Queries.list_season_episodes(season_id)
  end

  @doc """
  Gets the next episode after the given episode.

  First tries to find the next episode in the same season.
  If not found, tries to find the first episode of the next season.
  Returns nil if there's no next episode.
  """
  @spec get_next_episode(integer()) :: Episode.t() | nil
  def get_next_episode(episode_id) do
    Queries.get_next_episode(episode_id)
  end

  # =============================================================================
  # Search
  # =============================================================================

  @doc """
  Searches series across all visible providers (global + public + user's private).
  """
  @spec search(integer(), String.t(), keyword()) :: [Series.t()]
  def search(user_id, query, opts \\ []) do
    Queries.search(user_id, query, opts)
  end

  @doc """
  Searches series in public providers only (for guests).

  Uses `Streamix.Iptv.RankedSearch` so matches are ordered by
  relevance and the result includes a `:rank_score` virtual field.
  Unaccent-folds both sides so `"pokemon"` matches `"Pokémon"`, and
  trigram-similarity catches typos (`"Breakng Bad"` still finds it).
  """
  @spec search_public(String.t(), keyword()) :: [Series.t()]
  def search_public(query, opts \\ []) do
    Queries.search_public(query, opts)
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
    Enrichment.fetch_info(series)
  end

  @doc """
  Fetches detailed episode info from TMDB if not already enriched.
  Uses the series tmdb_id and season number to fetch the entire season,
  then matches by episode number.
  Returns {:ok, updated_episode} or {:error, reason}.
  """
  @spec fetch_episode_info(Episode.t()) :: {:ok, Episode.t()} | {:error, term()}
  def fetch_episode_info(%Episode{} = episode) do
    Enrichment.fetch_episode_info(episode)
  end

  @doc false
  def persist_series_assets(_series_id, _type, nil), do: :ok
  def persist_series_assets(_series_id, _type, []), do: :ok

  def persist_series_assets(series_id, type, urls) when is_list(urls) do
    Enrichment.persist_series_assets(series_id, type, urls)
  end

  @doc """
  Counts total episodes for a series by querying through seasons.
  """
  @spec count_episodes_for_series(integer()) :: integer()
  def count_episodes_for_series(series_id) do
    Queries.count_episodes_for_series(series_id)
  end
end
