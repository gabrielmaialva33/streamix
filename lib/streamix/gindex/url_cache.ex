defmodule Streamix.Gindex.UrlCache do
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

  alias Streamix.Gindex.{Client, EndpointPolicy}
  alias Streamix.Iptv

  require Logger

  @table_name :gindex_url_cache
  @default_ttl :timer.minutes(30)
  @refresh_margin :timer.minutes(5)
  @cleanup_interval :timer.minutes(10)

  @type content_type :: :movie | :episode

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the download URL for a movie.

  Returns a fresh URL, using cache if available and not expired.
  """
  @spec get_movie_url(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def get_movie_url(movie_id) do
    GenServer.call(__MODULE__, {:get_url, :movie, movie_id}, :timer.seconds(30))
  end

  @doc """
  Gets the download URL for an episode.

  Returns a fresh URL, using cache if available and not expired.
  """
  @spec get_episode_url(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def get_episode_url(episode_id) do
    GenServer.call(__MODULE__, {:get_url, :episode, episode_id}, :timer.seconds(30))
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
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_url, type, id}, _from, state) do
    {:reply, fetch_or_refresh_url(type, id), state}
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

  defp fetch_or_refresh_url(type, id) do
    cache_key = {type, id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, cache_key) do
      [{^cache_key, url, expires_at}] when expires_at > now + @refresh_margin ->
        {:ok, url}

      _other ->
        refresh_url(type, id)
    end
  end

  defp refresh_url(type, id) do
    with {:ok, source} <- Iptv.get_gindex_stream_source(type, id) do
      fetch_and_cache_url(type, id, source)
    end
  end

  defp fetch_and_cache_url(type, id, source) do
    base_url = EndpointPolicy.stream_url(source.base_url)

    case Client.get_download_url(base_url, source.path) do
      {:ok, url} ->
        cache_url({type, id}, url)
        persist_url(type, id, url)
        {:ok, url}

      {:error, reason} ->
        Logger.warning(
          "[GIndex UrlCache] Failed to get URL for #{type} #{id}: #{inspect(reason)}"
        )

        fallback_to_db_cache(type, id, source)
    end
  end

  defp persist_url(type, id, url) do
    expires_at = DateTime.utc_now(:second) |> DateTime.add(30, :minute)

    case Iptv.put_gindex_stream_cache(type, id, url, expires_at) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[GIndex UrlCache] Could not persist URL for #{type} #{id}: #{inspect(reason)}"
        )
    end
  end

  defp fallback_to_db_cache(type, id, source) do
    case source do
      %{cached_url: url, cached_until: %DateTime{} = expires_at}
      when is_binary(url) and url != "" ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          Logger.info("[GIndex UrlCache] Using fallback DB cache for #{type} #{id}")
          {:ok, url}
        else
          Logger.warning("[GIndex UrlCache] DB cache expired for #{type} #{id}")
          {:error, :url_expired}
        end

      _source ->
        {:error, :url_not_available}
    end
  end

  defp cache_url(cache_key, url) do
    expires_at = System.monotonic_time(:millisecond) + @default_ttl
    :ets.insert(@table_name, {cache_key, url, expires_at})
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    deleted_count = :ets.select_delete(@table_name, match_spec)

    if deleted_count > 0 do
      Logger.debug("[GIndex UrlCache] Cleaned up #{deleted_count} expired entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
