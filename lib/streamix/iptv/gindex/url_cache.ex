defmodule Streamix.Iptv.Gindex.UrlCache do
  @moduledoc """
  GenServer for caching GIndex download URLs.

  GIndex generates signed URLs with expiration. This cache stores the URLs
  and refreshes them before they expire.

  ## TTL
  URLs are cached for 30 minutes by default. When a URL is requested and
  the cached version is expired (or close to expiring), a fresh URL is
  fetched from the GIndex server.
  """

  use GenServer

  alias Streamix.Iptv.Gindex.Client
  alias Streamix.Iptv.{Episode, Movie}
  alias Streamix.Repo

  require Logger

  @table_name :gindex_url_cache
  @default_ttl :timer.minutes(30)
  @refresh_margin :timer.minutes(5)
  @cleanup_interval :timer.minutes(10)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the download URL for a movie.

  Returns a fresh URL, using cache if available and not expired.
  """
  def get_movie_url(movie_id) do
    GenServer.call(__MODULE__, {:get_movie_url, movie_id}, :timer.seconds(30))
  end

  @doc """
  Gets the download URL for an episode.

  Returns a fresh URL, using cache if available and not expired.
  """
  def get_episode_url(episode_id) do
    GenServer.call(__MODULE__, {:get_episode_url, episode_id}, :timer.seconds(30))
  end

  @doc """
  Invalidates the cached URL for a movie.
  """
  def invalidate(movie_id) do
    GenServer.cast(__MODULE__, {:invalidate, {:movie, movie_id}})
  end

  @doc """
  Invalidates the cached URL for an episode.
  """
  def invalidate_episode(episode_id) do
    GenServer.cast(__MODULE__, {:invalidate, {:episode, episode_id}})
  end

  @doc """
  Clears all cached URLs.
  """
  def clear_all do
    GenServer.cast(__MODULE__, :clear_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for cache
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_movie_url, movie_id}, _from, state) do
    result = fetch_or_refresh_movie_url(movie_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_episode_url, episode_id}, _from, state) do
    result = fetch_or_refresh_episode_url(episode_id)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:invalidate, cache_key}, state) do
    :ets.delete(@table_name, cache_key)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_all, state) do
    :ets.delete_all_objects(@table_name)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions - Movie URLs

  defp fetch_or_refresh_movie_url(movie_id) do
    cache_key = {:movie, movie_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, cache_key) do
      [{^cache_key, url, expires_at}] when expires_at > now + @refresh_margin ->
        # Cache hit and not close to expiring
        {:ok, url}

      _ ->
        # Cache miss or expired, fetch fresh URL
        refresh_movie_url(movie_id)
    end
  end

  defp refresh_movie_url(movie_id) do
    import Ecto.Query

    # Get movie with provider
    query =
      from m in Movie,
        where: m.id == ^movie_id,
        preload: [:provider]

    case Repo.one(query) do
      nil ->
        {:error, :movie_not_found}

      %Movie{gindex_path: nil} ->
        {:error, :not_gindex_movie}

      %Movie{gindex_path: path, provider: provider} ->
        fetch_and_cache_movie_url(movie_id, provider, path)
    end
  end

  defp fetch_and_cache_movie_url(movie_id, provider, path) do
    base_url = provider.gindex_url || provider.url

    case Client.get_download_url(base_url, path) do
      {:ok, url} ->
        cache_url({:movie, movie_id}, url)
        update_movie_cache(movie_id, url)
        {:ok, url}

      {:error, reason} ->
        Logger.warning(
          "[GIndex UrlCache] Failed to get URL for movie #{movie_id}: #{inspect(reason)}"
        )

        # Try to use cached URL from database as fallback
        fallback_to_movie_db_cache(movie_id)
    end
  end

  defp update_movie_cache(movie_id, url) do
    expires_at = DateTime.utc_now() |> DateTime.add(30, :minute)

    import Ecto.Query

    from(m in Movie, where: m.id == ^movie_id)
    |> Repo.update_all(set: [gindex_url_cached: url, gindex_url_expires_at: expires_at])
  end

  defp fallback_to_movie_db_cache(movie_id) do
    import Ecto.Query

    query =
      from m in Movie,
        where: m.id == ^movie_id,
        select: {m.gindex_url_cached, m.gindex_url_expires_at}

    case Repo.one(query) do
      {url, _expires_at} when is_binary(url) and url != "" ->
        # Use cached URL even if expired (better than nothing)
        Logger.info("[GIndex UrlCache] Using fallback DB cache for movie #{movie_id}")
        {:ok, url}

      _ ->
        {:error, :url_not_available}
    end
  end

  # Private functions - Episode URLs

  defp fetch_or_refresh_episode_url(episode_id) do
    cache_key = {:episode, episode_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, cache_key) do
      [{^cache_key, url, expires_at}] when expires_at > now + @refresh_margin ->
        # Cache hit and not close to expiring
        {:ok, url}

      _ ->
        # Cache miss or expired, fetch fresh URL
        refresh_episode_url(episode_id)
    end
  end

  defp refresh_episode_url(episode_id) do
    import Ecto.Query

    # Get episode with season -> series -> provider
    query =
      from e in Episode,
        where: e.id == ^episode_id,
        preload: [season: [series: :provider]]

    case Repo.one(query) do
      nil ->
        {:error, :episode_not_found}

      %Episode{gindex_path: nil} ->
        {:error, :not_gindex_episode}

      %Episode{gindex_path: path, season: %{series: %{provider: provider}}} ->
        fetch_and_cache_episode_url(episode_id, provider, path)
    end
  end

  defp fetch_and_cache_episode_url(episode_id, provider, path) do
    base_url = provider.gindex_url || provider.url

    case Client.get_download_url(base_url, path) do
      {:ok, url} ->
        cache_url({:episode, episode_id}, url)
        update_episode_cache(episode_id, url)
        {:ok, url}

      {:error, reason} ->
        Logger.warning(
          "[GIndex UrlCache] Failed to get URL for episode #{episode_id}: #{inspect(reason)}"
        )

        # Try to use cached URL from database as fallback
        fallback_to_episode_db_cache(episode_id)
    end
  end

  defp update_episode_cache(episode_id, url) do
    expires_at = DateTime.utc_now() |> DateTime.add(30, :minute)

    import Ecto.Query

    from(e in Episode, where: e.id == ^episode_id)
    |> Repo.update_all(set: [gindex_url_cached: url, gindex_url_expires_at: expires_at])
  end

  defp fallback_to_episode_db_cache(episode_id) do
    import Ecto.Query

    query =
      from e in Episode,
        where: e.id == ^episode_id,
        select: {e.gindex_url_cached, e.gindex_url_expires_at}

    case Repo.one(query) do
      {url, _expires_at} when is_binary(url) and url != "" ->
        # Use cached URL even if expired (better than nothing)
        Logger.info("[GIndex UrlCache] Using fallback DB cache for episode #{episode_id}")
        {:ok, url}

      _ ->
        {:error, :url_not_available}
    end
  end

  # Common cache function

  defp cache_url(cache_key, url) do
    expires_at = System.monotonic_time(:millisecond) + @default_ttl
    :ets.insert(@table_name, {cache_key, url, expires_at})
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Find and delete expired entries
    expired =
      :ets.select(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))

    if expired != [] do
      Logger.debug("[GIndex UrlCache] Cleaned up #{length(expired)} expired entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
