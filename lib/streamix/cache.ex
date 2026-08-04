defmodule Streamix.Cache do
  @moduledoc """
  Hybrid L1+L2 caching for categories and metadata.

  L1: `Streamix.Cache.L1` (ConCache, in-memory, per-node) — microsecond
  access, hot data.
  L2: `Streamix.Cache.L2` (Redis, distributed) — millisecond access,
  cluster-wide consistency.

  Read path: L1 → L2 (populate L1 on hit).
  Write path: L1 + L2 (write-through).

  Key builders live in `Streamix.Cache.Keys` so invalidation patterns
  always match what we write.

  This facade exposes:

    * `get/1`, `set/3`, `delete/1` — explicit ops
    * `fetch/3` — get-or-compute with stampede prevention
    * `fetch_categories/3`, `fetch_public_stats/1`, `fetch_featured/1`,
      `fetch_tmdb_*` — opinionated wrappers with the right TTL/key
    * `invalidate_*` — surgical pattern-based eviction
    * `stats/0` — L1+L2 snapshot
  """

  alias Streamix.Cache.{Keys, L1, L2}

  @default_ttl 3600
  @categories_ttl 6 * 3600
  @stats_ttl 30 * 60
  @featured_ttl 24 * 3600
  # TMDB metadata is static, cache for 24h
  @tmdb_ttl 24 * 3600
  # Search results may change, cache for 1h
  @tmdb_search_ttl 3600

  # =============================================================================
  # Core Operations
  # =============================================================================

  @doc """
  Gets a value from cache. Returns nil if not found or expired.
  Checks L1 (in-memory) first, then L2 (Redis).
  """
  @spec get(String.t()) :: term() | nil
  def get(key) do
    case L1.get(key) do
      nil -> populate_l1_from_l2(key)
      value -> value
    end
  end

  defp populate_l1_from_l2(key) do
    case L2.get(key) do
      nil ->
        nil

      {value, ttl_ms} ->
        L1.put(key, value, ttl_ms)
        value
    end
  end

  @doc """
  Sets a value in cache with optional TTL (in seconds).
  Writes to both L1 (in-memory) and L2 (Redis) for consistency.
  """
  @spec set(String.t(), term(), pos_integer()) :: :ok | {:error, term()}
  def set(key, value, ttl \\ @default_ttl) do
    L1.put(key, value, ttl * 1000)
    L2.set(key, value, ttl)
  end

  @doc """
  Deletes a key from cache.
  Removes from both L1 (in-memory) and L2 (Redis).
  """
  @spec delete(String.t()) :: :ok
  def delete(key) do
    L1.delete(key)
    L2.delete(key)
  end

  @doc """
  Deletes all keys matching a pattern using SCAN (non-blocking).
  Safer than KEYS for production — doesn't block Redis.
  """
  @spec delete_pattern(String.t()) :: {:ok, non_neg_integer()}
  def delete_pattern(pattern) do
    L2.delete_pattern(pattern, &L1.delete/1)
  end

  @doc """
  Gets a value through the in-memory (L1-only) cache, or computes and
  caches it if not found.

  Use instead of `fetch/3` for values that must never be serialized into
  Redis — e.g. structs carrying decrypted credentials. Entries are
  per-node: each node computes and invalidates its own copy, so keep the
  TTL short when cross-node staleness matters. `nil` results are not
  memoised.
  """
  @spec fetch_local(term(), pos_integer(), (-> term())) :: term()
  def fetch_local(key, ttl_ms, fun) when is_function(fun, 0) do
    if Application.get_env(:streamix, :disable_local_cache, false) do
      fun.()
    else
      case L1.get(key) do
        nil ->
          value = fun.()
          L1.put(key, value, ttl_ms)
          value

        value ->
          value
      end
    end
  end

  @doc "Removes an entry written by `fetch_local/3` from this node's L1."
  @spec delete_local(term()) :: :ok
  def delete_local(key) do
    L1.delete(key)
    :ok
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

    if L1.cacheable?(ttl_ms) do
      fetch_with_l1(key, ttl, ttl_ms, fun)
    else
      fetch_without_l1(key, ttl, fun)
    end
  end

  defp fetch_with_l1(key, ttl, ttl_ms, fun) do
    # ConCache.get_or_store prevents stampede — concurrent callers on the
    # same key block on the first computation instead of racing.
    l1_ttl_ms = min(ttl_ms, L1.l1_ttl())

    L1.get_or_store(key, fn ->
      value =
        case L2.get(key) do
          nil ->
            computed = fun.()
            L2.set(key, computed, ttl)
            computed

          {cached, _ttl_ms} ->
            cached
        end

      %ConCache.Item{value: value, ttl: l1_ttl_ms}
    end)
  end

  defp fetch_without_l1(key, ttl, fun) do
    case L2.get(key) do
      nil ->
        value = fun.()
        L2.set(key, value, ttl)
        value

      {value, _ttl_ms} ->
        value
    end
  end

  # =============================================================================
  # Re-exports for legacy callers
  # =============================================================================

  defdelegate l1_ttl, to: L1
  defdelegate l1_ttl_check_interval, to: L1

  defdelegate categories_key(user_id), to: Keys, as: :categories
  defdelegate provider_categories_key(provider_id), to: Keys, as: :provider_categories
  defdelegate channel_count_key(provider_id), to: Keys, as: :channel_count
  defdelegate groups_key(user_id), to: Keys, as: :groups
  defdelegate user_profile_key(user_id), to: Keys, as: :user_profile
  defdelegate user_insights_key(user_id), to: Keys, as: :user_insights

  defdelegate recommendations_key(user_id, type, limit, exclude_watched),
    to: Keys,
    as: :recommendations

  defdelegate public_stats_key, to: Keys, as: :public_stats
  defdelegate featured_key, to: Keys, as: :featured
  defdelegate epg_now_key(provider_id, epg_channel_id), to: Keys, as: :epg_now
  defdelegate epg_current_key(provider_id, epg_channel_id), to: Keys, as: :epg_current
  defdelegate tmdb_movie_key(tmdb_id), to: Keys, as: :tmdb_movie
  defdelegate tmdb_series_key(tmdb_id), to: Keys, as: :tmdb_series
  defdelegate tmdb_season_key(series_id, season_num), to: Keys, as: :tmdb_season
  defdelegate tmdb_search_movie_key(query, opts), to: Keys, as: :tmdb_search_movie
  defdelegate tmdb_search_series_key(query, opts), to: Keys, as: :tmdb_search_series

  # =============================================================================
  # High-Level Caching Functions
  # =============================================================================

  @doc "Gets or computes categories for a provider"
  def fetch_categories(provider_id, type, fun) do
    key = "#{Keys.provider_categories(provider_id)}:#{type || "all"}"
    fetch(key, @categories_ttl, fun)
  end

  @doc "Gets or computes public stats"
  def fetch_public_stats(fun), do: fetch(Keys.public_stats(), @stats_ttl, fun)

  @doc "Gets or computes featured content (cached daily)"
  def fetch_featured(fun), do: fetch(Keys.featured(), @featured_ttl, fun)

  @doc "Gets or computes TMDB movie metadata"
  def fetch_tmdb_movie(tmdb_id, fun), do: fetch(Keys.tmdb_movie(tmdb_id), @tmdb_ttl, fun)

  @doc "Gets or computes TMDB series metadata"
  def fetch_tmdb_series(tmdb_id, fun), do: fetch(Keys.tmdb_series(tmdb_id), @tmdb_ttl, fun)

  @doc "Gets or computes TMDB season metadata"
  def fetch_tmdb_season(series_id, season_num, fun) do
    fetch(Keys.tmdb_season(series_id, season_num), @tmdb_ttl, fun)
  end

  @doc "Gets or computes TMDB movie search results"
  def fetch_tmdb_search_movie(query, opts, fun) do
    fetch(Keys.tmdb_search_movie(query, opts), @tmdb_search_ttl, fun)
  end

  @doc "Gets or computes TMDB series search results"
  def fetch_tmdb_search_series(query, opts, fun) do
    fetch(Keys.tmdb_search_series(query, opts), @tmdb_search_ttl, fun)
  end

  # =============================================================================
  # Stats & Monitoring
  # =============================================================================

  @doc "Returns cache statistics for monitoring."
  @spec stats() :: %{l1: map(), l2: map()}
  def stats, do: %{l1: L1.stats(), l2: L2.stats()}

  # =============================================================================
  # Invalidation
  # =============================================================================

  @doc "Invalidates all cache entries for a user."
  @spec invalidate_user(integer()) :: {:ok, non_neg_integer()}
  def invalidate_user(user_id) do
    {:ok, user_entries} =
      invalidate_patterns(["*:user:#{user_id}", "*:user:#{user_id}:*"])

    {:ok, personalization_entries} = invalidate_personalization(user_id)
    {:ok, user_entries + personalization_entries}
  end

  @doc "Invalidates derived profile, recommendation, insight and home personalization data."
  @spec invalidate_personalization(integer()) :: {:ok, non_neg_integer()}
  def invalidate_personalization(user_id) do
    # Remove legacy exact keys as well so rolling deploys cannot resurrect
    # personalization written by an older node.
    delete("user_profile:#{user_id}")
    delete("user_insights:#{user_id}")

    invalidate_patterns([
      "ai:user:#{user_id}:*",
      "home:*:user:#{user_id}:*",
      "recommendations:#{user_id}:*"
    ])
  end

  defp invalidate_patterns(patterns) do
    count =
      Enum.reduce(patterns, 0, fn pattern, total ->
        {:ok, deleted_count} = delete_pattern(pattern)
        total + deleted_count
      end)

    {:ok, count}
  end

  @doc "Invalidates all cache entries for a provider."
  @spec invalidate_provider(integer()) :: {:ok, non_neg_integer()}
  def invalidate_provider(provider_id), do: delete_pattern("*:provider:#{provider_id}")

  @doc "Invalidates all EPG cache entries for a provider."
  @spec invalidate_provider_epg(integer()) :: {:ok, non_neg_integer()}
  def invalidate_provider_epg(provider_id), do: delete_pattern("epg:*:#{provider_id}:*")

  @doc """
  Invalidates all cache entries. Use with caution.
  Clears L1 and every L2 entry owned by the `cache:` Redis namespace.
  Operational Redis state owned by other subsystems is preserved.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    L1.clear()
    _ = L2.delete_pattern("*")
    :ok
  end
end
