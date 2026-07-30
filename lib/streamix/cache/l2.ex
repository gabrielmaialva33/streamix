defmodule Streamix.Cache.L2 do
  @moduledoc """
  Redis-backed L2 cache layer for `Streamix.Cache`.

  Encapsulates Redix pipelines, term encoding, and SCAN-based pattern
  deletion. Returns plain values (decoded Erlang terms) so the hybrid
  layer above doesn't deal with raw binaries.
  """

  require Logger

  @redis :streamix_redis
  @namespace "cache:"
  @scan_count 100

  @doc """
  Fetch a key from Redis. Returns `{value, ttl_ms}` on hit (so the caller
  can promote into L1 with the same TTL) or `nil` on miss / error.
  """
  def get(key) do
    redis_key = redis_key(key)

    case Redix.pipeline(@redis, [["GET", redis_key], ["PTTL", redis_key]]) do
      {:ok, [nil, _]} ->
        nil

      {:ok, [value, ttl_ms]} ->
        {decode(value), ttl_ms}

      {:error, reason} ->
        log_error("GET", key, reason)
        nil
    end
  end

  @doc "Write a key with TTL in seconds."
  def set(key, value, ttl_seconds) do
    case encode(value) do
      {:ok, encoded} ->
        case Redix.command(@redis, ["SETEX", redis_key(key), ttl_seconds, encoded]) do
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

  @doc "Delete a single key."
  def delete(key) do
    case Redix.command(@redis, ["DEL", redis_key(key)]) do
      {:ok, _} -> :ok
      {:error, reason} -> log_error("DEL", key, reason)
    end

    :ok
  end

  @doc """
  Delete every key matching `pattern` via `SCAN` + `DEL`. SCAN is
  cooperatively non-blocking — KEYS would lock Redis for the duration of
  the wildcard match, which is unsafe in prod.

  Accepts a `on_key_deleted` callback so callers (the hybrid facade) can
  evict the same key from L1 in lockstep.
  """
  def delete_pattern(pattern, on_key_deleted \\ fn _key -> :ok end)
      when is_function(on_key_deleted, 1) do
    callback = fn key -> key |> logical_key() |> on_key_deleted.() end
    count = scan_and_delete(redis_pattern(pattern), "0", 0, callback)
    {:ok, count}
  end

  @doc "L2 size snapshot for `Streamix.Cache.stats/0`."
  def stats do
    case Redix.command(@redis, ["DBSIZE"]) do
      {:ok, size} -> %{size: size}
      {:error, _} -> %{size: :unavailable}
    end
  end

  # ----- internals -----

  defp redis_key(key), do: @namespace <> key
  defp redis_pattern(pattern), do: @namespace <> pattern
  defp logical_key(@namespace <> key), do: key

  defp scan_and_delete(pattern, cursor, count, on_key_deleted) do
    case Redix.command(@redis, ["SCAN", cursor, "MATCH", pattern, "COUNT", @scan_count]) do
      {:ok, ["0", []]} ->
        count

      {:ok, ["0", keys]} ->
        count + delete_keys(keys, on_key_deleted)

      {:ok, [next_cursor, keys]} ->
        deleted = delete_keys(keys, on_key_deleted)
        scan_and_delete(pattern, next_cursor, count + deleted, on_key_deleted)

      {:error, reason} ->
        log_error("SCAN", pattern, reason)
        count
    end
  end

  defp delete_keys([], _on_key_deleted), do: 0

  defp delete_keys(keys, on_key_deleted) do
    Enum.each(keys, on_key_deleted)

    case Redix.command(@redis, ["DEL" | keys]) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp encode(value) do
    {:ok, :erlang.term_to_binary(value)}
  rescue
    e -> {:error, {:encode_error, e}}
  end

  # Redis values are emitted exclusively by encode/1 above and the :safe
  # option prevents creation of executable or unknown runtime terms.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(value) do
    :erlang.binary_to_term(value, [:safe])
  rescue
    _ -> nil
  end

  defp log_error(operation, key, reason) do
    Logger.warning("Cache.L2 #{operation} failed for #{key}: #{inspect(reason)}")
  end
end
