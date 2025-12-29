defmodule Streamix.Cache do
  @moduledoc """
  Redis-based caching for categories and metadata.
  Uses Redix for Redis connection.

  This module provides a simple caching interface with:
  - Automatic TTL handling
  - Safe pattern-based invalidation using SCAN (non-blocking)
  - Fetch-or-compute pattern for cache warming
  """

  require Logger

  @redis :streamix_redis
  @default_ttl 3600
  @scan_count 100

  # =============================================================================
  # Core Operations
  # =============================================================================

  @doc """
  Gets a value from cache. Returns nil if not found or expired.
  """
  @spec get(String.t()) :: term() | nil
  def get(key) do
    case Redix.command(@redis, ["GET", key]) do
      {:ok, nil} ->
        nil

      {:ok, value} ->
        decode(value)

      {:error, reason} ->
        log_error("GET", key, reason)
        nil
    end
  end

  @doc """
  Sets a value in cache with optional TTL (in seconds).
  """
  @spec set(String.t(), term(), pos_integer()) :: :ok | {:error, term()}
  def set(key, value, ttl \\ @default_ttl) do
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
  """
  @spec delete(String.t()) :: :ok
  def delete(key) do
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
    case get(key) do
      nil ->
        value = fun.()
        set(key, value, ttl)
        value

      value ->
        value
    end
  end

  # =============================================================================
  # Cache Keys
  # =============================================================================

  @doc "Cache key for user categories"
  @spec categories_key(integer()) :: String.t()
  def categories_key(user_id), do: "categories:user:#{user_id}"

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
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    case Redix.command(@redis, ["FLUSHDB"]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error("FLUSHDB", "*", reason)
        :ok
    end
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
    case Redix.command(@redis, ["DEL" | keys]) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp log_error(operation, key, reason) do
    Logger.warning("Cache #{operation} failed for #{key}: #{inspect(reason)}")
  end
end
