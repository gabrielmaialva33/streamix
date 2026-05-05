defmodule Streamix.Cache do
  @moduledoc """
  Hybrid L1+L2 caching for categories and metadata.

  L1: ConCache (in-memory, per-node) - microsecond access, hot data
  L2: Redis (distributed) - millisecond access, cluster-wide consistency

  Read path: L1 -> L2 (populate L1 on hit)
  Write path: L1 + L2 (write-through)

  This module provides a simple caching interface with:
  - Automatic TTL handling
  - Safe pattern-based invalidation using SCAN (non-blocking)
  - Fetch-or-compute pattern for cache warming
  """

  require Logger

  @l1_cache :streamix_l1_cache
  @redis :streamix_redis
  @default_ttl 3600
  @l1_ttl :timer.minutes(30)
  @l1_ttl_check_interval :timer.seconds(30)
  @scan_count 100

  # =============================================================================
  # Core Operations
  # =============================================================================

  @doc """
  Gets a value from cache. Returns nil if not found or expired.
  Checks L1 (in-memory) first, then L2 (Redis).
  """
  @spec get(String.t()) :: term() | nil
  def get(key) do
    # Try L1 first (microsecond access)
    case ConCache.get(@l1_cache, key) do
      nil ->
        # L1 miss, try L2 (Redis)
        get_from_l2(key)

      value ->
        # L1 hit
        value
    end
  end

  # Get from L2 and populate L1 on hit
  defp get_from_l2(key, opts \\ []) do
    populate_l1? = Keyword.get(opts, :populate_l1?, true)

    case Redix.pipeline(@redis, [["GET", key], ["PTTL", key]]) do
      {:ok, [nil, _ttl_ms]} ->
        nil

      {:ok, [value, ttl_ms]} ->
        decoded = decode(value)

        if populate_l1? do
          maybe_put_l1(key, decoded, ttl_ms)
        end

        decoded

      {:error, reason} ->
        log_error("GET", key, reason)
        nil
    end
  end

  @doc """
  Sets a value in cache with optional TTL (in seconds).
  Writes to both L1 (in-memory) and L2 (Redis) for consistency.
  """
  @spec set(String.t(), term(), pos_integer()) :: :ok | {:error, term()}
  def set(key, value, ttl \\ @default_ttl) do
    # Write to L1 first (local node)
    maybe_put_l1(key, value, ttl * 1000)

    # Write to L2 (Redis) for persistence and cluster sharing
    case encode(value) do
      {:ok, encoded} ->
        case Redix.command(@redis, ["SETEX", key, ttl, encoded]) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            log_error("SETEX", key, reason)
            {:error, reason}
        end

      {:error, reason} ->
        log_error("encode", key, reason)
        {:error, reason}
    end
  end

  @doc """
  Deletes a key from cache.
  Removes from both L1 (in-memory) and L2 (Redis).
  """
  @spec delete(String.t()) :: :ok
  def delete(key) do
    # Delete from L1
    ConCache.delete(@l1_cache, key)

    # Delete from L2
    case Redix.command(@redis, ["DEL", key]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error("DEL", key, reason)
        :ok
    end
  end

  @doc """
  Deletes all keys matching a pattern using SCAN (non-blocking).
  This is safer than KEYS for production use as it doesn't block Redis.
  """
  @spec delete_pattern(String.t()) :: {:ok, non_neg_integer()}
  def delete_pattern(pattern) do
    count = scan_and_delete(pattern, "0", 0)
    {:ok, count}
  end

  @doc """
  Gets a value from cache, or computes and caches it if not found.
  This is the recommended way to use the cache.

  ## Example

      Cache.fetch("user:123:data", 3600, fn ->
        expensive_computation()
      end)
  """
  @spec fetch(String.t(), pos_integer(), (-> term())) :: term()
  def fetch(key, ttl \\ @default_ttl, fun) when is_function(fun, 0) do
    ttl_ms = ttl * 1000

    if cache_in_l1?(ttl_ms) do
      fetch_with_l1(key, ttl, ttl_ms, fun)
    else
      fetch_without_l1(key, ttl, fun)
    end
  end

  # Write only to L2 (Redis), used by fetch to avoid double L1 write
  defp set_l2(key, value, ttl) do
    case encode(value) do
      {:ok, encoded} ->
        case Redix.command(@redis, ["SETEX", key, ttl, encoded]) do
          {:ok, _} -> :ok
          {:error, reason} -> log_error("SETEX", key, reason)
        end

      {:error, reason} ->
        log_error("encode", key, reason)
    end
  end

  # =============================================================================
  # Cache Keys
  # =============================================================================

  @doc "Cache key for user categories"
  @spec categories_key(integer()) :: String.t()
  def categories_key(user_id), do: "categories:user:#{user_id}"

  def l1_ttl, do: @l1_ttl
  def l1_ttl_check_interval, do: @l1_ttl_check_interval

  @doc "Cache key for provider categories"
  @spec provider_categories_key(integer()) :: String.t()
  def provider_categories_key(provider_id), do: "categories:provider:#{provider_id}"

  @doc "Cache key for provider channel count"
  @spec channel_count_key(integer()) :: String.t()
  def channel_count_key(provider_id), do: "channel_count:provider:#{provider_id}"

  @doc "Cache key for user groups"
  @spec groups_key(integer()) :: String.t()
  def groups_key(user_id), do: "groups:user:#{user_id}"

  @doc "Cache key for public stats"
  @spec public_stats_key() :: String.t()
  def public_stats_key, do: "stats:public"

  @doc "Cache key for featured content (daily)"
  @spec featured_key() :: String.t()
  def featured_key, do: "featured:#{Date.utc_today()}"

  @doc "Cache key for EPG now/next for a channel"
  @spec epg_now_key(integer(), String.t()) :: String.t()
  def epg_now_key(provider_id, epg_channel_id),
    do: "epg:now:#{provider_id}:#{epg_channel_id}"

  @doc "Cache key for the currently airing EPG program for a channel (batch lookups)"
  @spec epg_current_key(integer(), String.t()) :: String.t()
  def epg_current_key(provider_id, epg_channel_id),
    do: "epg:current:#{provider_id}:#{epg_channel_id}"

  @doc "Cache key for TMDB movie metadata"
  @spec tmdb_movie_key(integer() | String.t()) :: String.t()
  def tmdb_movie_key(tmdb_id), do: "tmdb:movie:#{tmdb_id}"

  @doc "Cache key for TMDB series metadata"
  @spec tmdb_series_key(integer() | String.t()) :: String.t()
  def tmdb_series_key(tmdb_id), do: "tmdb:series:#{tmdb_id}"

  @doc "Cache key for TMDB season metadata"
  @spec tmdb_season_key(integer() | String.t(), integer()) :: String.t()
  def tmdb_season_key(series_id, season_num), do: "tmdb:season:#{series_id}:#{season_num}"

  @doc "Cache key for TMDB movie search"
  @spec tmdb_search_movie_key(String.t(), Keyword.t()) :: String.t()
  def tmdb_search_movie_key(query, opts) do
    year = opts[:year]
    hash = :erlang.phash2({query, year})
    "tmdb:search:movie:#{hash}"
  end

  @doc "Cache key for TMDB series search"
  @spec tmdb_search_series_key(String.t(), Keyword.t()) :: String.t()
  def tmdb_search_series_key(query, opts) do
    year = opts[:year]
    hash = :erlang.phash2({query, year})
    "tmdb:search:series:#{hash}"
  end

  # =============================================================================
  # High-Level Caching Functions
  # =============================================================================

  @categories_ttl 6 * 3600
  @stats_ttl 30 * 60
  @featured_ttl 24 * 3600

  @doc "Gets or computes categories for a provider"
  def fetch_categories(provider_id, type, fun) do
    key = "#{provider_categories_key(provider_id)}:#{type || "all"}"
    fetch(key, @categories_ttl, fun)
  end

  @doc "Gets or computes public stats"
  def fetch_public_stats(fun) do
    fetch(public_stats_key(), @stats_ttl, fun)
  end

  @doc "Gets or computes featured content (cached daily)"
  def fetch_featured(fun) do
    fetch(featured_key(), @featured_ttl, fun)
  end

  # TMDB metadata is static, cache for 24h
  @tmdb_ttl 24 * 3600
  # Search results may change, cache for 1h
  @tmdb_search_ttl 3600

  @doc "Gets or computes TMDB movie metadata"
  def fetch_tmdb_movie(tmdb_id, fun) do
    fetch(tmdb_movie_key(tmdb_id), @tmdb_ttl, fun)
  end

  @doc "Gets or computes TMDB series metadata"
  def fetch_tmdb_series(tmdb_id, fun) do
    fetch(tmdb_series_key(tmdb_id), @tmdb_ttl, fun)
  end

  @doc "Gets or computes TMDB season metadata"
  def fetch_tmdb_season(series_id, season_num, fun) do
    fetch(tmdb_season_key(series_id, season_num), @tmdb_ttl, fun)
  end

  @doc "Gets or computes TMDB movie search results"
  def fetch_tmdb_search_movie(query, opts, fun) do
    fetch(tmdb_search_movie_key(query, opts), @tmdb_search_ttl, fun)
  end

  @doc "Gets or computes TMDB series search results"
  def fetch_tmdb_search_series(query, opts, fun) do
    fetch(tmdb_search_series_key(query, opts), @tmdb_search_ttl, fun)
  end

  # =============================================================================
  # Stats & Monitoring
  # =============================================================================

  @doc """
  Returns cache statistics for monitoring.
  Useful for debugging and performance tuning.
  """
  @spec stats() :: %{l1: map(), l2: map()}
  def stats do
    l1_stats = l1_stats()
    l2_stats = l2_stats()
    %{l1: l1_stats, l2: l2_stats}
  end

  defp l1_stats do
    ets_table = ConCache.ets(@l1_cache)
    size = :ets.info(ets_table, :size)
    memory = :ets.info(ets_table, :memory) * :erlang.system_info(:wordsize)
    %{size: size, memory_bytes: memory}
  end

  defp l2_stats do
    case Redix.command(@redis, ["DBSIZE"]) do
      {:ok, size} -> %{size: size}
      {:error, _} -> %{size: :unavailable}
    end
  end

  # =============================================================================
  # Invalidation
  # =============================================================================

  @doc """
  Invalidates all cache entries for a user.
  """
  @spec invalidate_user(integer()) :: {:ok, non_neg_integer()}
  def invalidate_user(user_id) do
    delete_pattern("*:user:#{user_id}")
  end

  @doc """
  Invalidates all cache entries for a provider.
  """
  @spec invalidate_provider(integer()) :: {:ok, non_neg_integer()}
  def invalidate_provider(provider_id) do
    delete_pattern("*:provider:#{provider_id}")
  end

  @doc """
  Invalidates all EPG cache entries for a provider.
  """
  @spec invalidate_provider_epg(integer()) :: {:ok, non_neg_integer()}
  def invalidate_provider_epg(provider_id) do
    delete_pattern("epg:*:#{provider_id}:*")
  end

  @doc """
  Invalidates all cache entries. Use with caution.
  Clears both L1 (in-memory) and L2 (Redis).
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    # Clear L1 cache
    clear_l1_cache()

    # Clear L2 cache
    case Redix.command(@redis, ["FLUSHDB"]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error("FLUSHDB", "*", reason)
        delete_pattern("*")
        :ok
    end
  end

  # Clear all entries from L1 ConCache
  defp clear_l1_cache do
    # ConCache uses ETS under the hood, access via its internal table
    ets_table = ConCache.ets(@l1_cache)
    :ets.delete_all_objects(ets_table)
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  # Recursively scan and delete keys matching pattern using SCAN
  # SCAN is non-blocking and safe for production, unlike KEYS which blocks Redis
  defp scan_and_delete(pattern, cursor, count) do
    case Redix.command(@redis, ["SCAN", cursor, "MATCH", pattern, "COUNT", @scan_count]) do
      {:ok, ["0", []]} ->
        count

      {:ok, ["0", keys]} ->
        count + delete_keys(keys)

      {:ok, [next_cursor, keys]} ->
        deleted = delete_keys(keys)
        scan_and_delete(pattern, next_cursor, count + deleted)

      {:error, reason} ->
        log_error("SCAN", pattern, reason)
        count
    end
  end

  defp delete_keys([]), do: 0

  defp delete_keys(keys) do
    # Delete from L1 first
    Enum.each(keys, &ConCache.delete(@l1_cache, &1))

    # Delete from L2
    case Redix.command(@redis, ["DEL" | keys]) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp encode(value) do
    # Use Erlang term_to_binary to preserve Elixir types (atoms, structs, etc.)
    {:ok, :erlang.term_to_binary(value)}
  rescue
    e -> {:error, {:encode_error, e}}
  end

  defp decode(value) do
    # Use Erlang binary_to_term to restore Elixir types
    :erlang.binary_to_term(value, [:safe])
  rescue
    _ -> nil
  end

  defp log_error(operation, key, reason) do
    Logger.warning("Cache #{operation} failed for #{key}: #{inspect(reason)}")
  end

  defp maybe_put_l1(_key, nil, _ttl_ms), do: :ok

  defp maybe_put_l1(key, value, ttl_ms) do
    if cache_in_l1?(ttl_ms) do
      ConCache.put(@l1_cache, key, %ConCache.Item{value: value, ttl: min(ttl_ms, @l1_ttl)})
    end
  end

  defp cache_in_l1?(ttl_ms) when ttl_ms == -1, do: true
  defp cache_in_l1?(ttl_ms) when ttl_ms > @l1_ttl_check_interval, do: true
  defp cache_in_l1?(_ttl_ms), do: false

  defp fetch_with_l1(key, ttl, ttl_ms, fun) do
    # Use ConCache.get_or_store for L1 to prevent stampede —
    # concurrent callers on the same key will block on the first computation
    # instead of all computing simultaneously.
    l1_ttl_ms = min(ttl_ms, @l1_ttl)

    ConCache.get_or_store(@l1_cache, key, fn ->
      build_l1_cache_item(key, ttl, l1_ttl_ms, fun)
    end)
  end

  defp build_l1_cache_item(key, ttl, l1_ttl_ms, fun) do
    value =
      case get_from_l2(key) do
        nil ->
          computed = fun.()
          set_l2(key, computed, ttl)
          computed

        cached ->
          cached
      end

    %ConCache.Item{value: value, ttl: l1_ttl_ms}
  end

  defp fetch_without_l1(key, ttl, fun) do
    case get_from_l2(key, populate_l1?: false) do
      nil ->
        value = fun.()
        set_l2(key, value, ttl)
        value

      value ->
        value
    end
  end
end
