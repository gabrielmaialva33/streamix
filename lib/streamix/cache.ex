defmodule Streamix.Cache do
  @moduledoc """
  Redis-based caching for categories and metadata.
  Uses Redix for Redis connection.
  """

  @redis :streamix_redis
  # 1 hour in seconds
  @default_ttl 3600

  @doc """
  Gets a value from cache. Returns nil if not found or expired.
  """
  def get(key) do
    case Redix.command(@redis, ["GET", key]) do
      {:ok, nil} -> nil
      {:ok, value} -> Jason.decode!(value)
      {:error, _} -> nil
    end
  end

  @doc """
  Sets a value in cache with optional TTL (in seconds).
  """
  def set(key, value, ttl \\ @default_ttl) do
    encoded = Jason.encode!(value)
    Redix.command(@redis, ["SETEX", key, ttl, encoded])
  end

  @doc """
  Deletes a key from cache.
  """
  def delete(key) do
    Redix.command(@redis, ["DEL", key])
  end

  @doc """
  Deletes all keys matching a pattern.
  """
  def delete_pattern(pattern) do
    case Redix.command(@redis, ["KEYS", pattern]) do
      {:ok, keys} when keys != [] ->
        Redix.command(@redis, ["DEL" | keys])

      _ ->
        {:ok, 0}
    end
  end

  @doc """
  Gets a value from cache, or computes and caches it if not found.
  """
  def fetch(key, ttl \\ @default_ttl, fun) do
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

  def categories_key(user_id), do: "categories:user:#{user_id}"
  def provider_categories_key(provider_id), do: "categories:provider:#{provider_id}"
  def channel_count_key(provider_id), do: "channel_count:provider:#{provider_id}"
  def groups_key(user_id), do: "groups:user:#{user_id}"

  # =============================================================================
  # Invalidation
  # =============================================================================

  @doc """
  Invalidates all cache for a user.
  """
  def invalidate_user(user_id) do
    delete_pattern("*:user:#{user_id}")
  end

  @doc """
  Invalidates all cache for a provider.
  """
  def invalidate_provider(provider_id) do
    delete_pattern("*:provider:#{provider_id}")
  end

  @doc """
  Invalidates all cache.
  """
  def invalidate_all do
    Redix.command(@redis, ["FLUSHDB"])
  end
end
