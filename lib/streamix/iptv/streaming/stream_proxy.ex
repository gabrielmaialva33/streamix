defmodule Streamix.Iptv.StreamProxy do
  @moduledoc """
  A streaming proxy that caches IPTV stream chunks to reduce buffering.

  Uses ETS for fast in-memory caching with automatic expiration.
  Implements chunked streaming for smooth playback.

  ## GIndex Support

  For GIndex content, URLs are signed with expiration. Use `stream_gindex/1`
  which fetches fresh URLs via the UrlCache GenServer.
  """
  use GenServer
  require Logger

  alias Streamix.Gindex.UrlCache

  @cache_table :stream_proxy_cache
  # 5 minutes cache
  @cache_ttl_seconds 300
  # Cleanup every minute
  @cleanup_interval_ms 60_000
  # 30 seconds timeout
  @request_timeout 30_000
  # Max total cache size: 500 MB
  @max_cache_bytes 500 * 1024 * 1024
  # Max single entry size: 50 MB — don't cache anything larger
  @max_entry_bytes 50 * 1024 * 1024
  # Max number of cached entries
  @max_cache_entries 50

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Streams content from a URL, using cache when available.
  Returns {:ok, :cached, data} or {:ok, :stream, stream_fun}.
  """
  def stream(url) when is_binary(url) do
    cache_key = cache_key(url)

    case get_cached(cache_key) do
      {:ok, data} ->
        Logger.debug("StreamProxy: Cache hit for #{truncate_url(url)}")
        {:ok, :cached, data}

      :miss ->
        Logger.debug("StreamProxy: Cache miss, fetching #{truncate_url(url)}")
        stream_from_url(url, cache_key)
    end
  end

  @doc """
  Streams content from a GIndex movie by ID.

  Fetches a fresh download URL from the UrlCache and streams the content.
  The URL is cached for 30 minutes and refreshed when needed.
  """
  def stream_gindex(movie_id) when is_integer(movie_id) do
    case UrlCache.get_movie_url(movie_id) do
      {:ok, url} ->
        Logger.debug("StreamProxy: Got GIndex URL for movie #{movie_id}")
        stream(url)

      {:error, reason} ->
        Logger.warning(
          "StreamProxy: Failed to get GIndex URL for movie #{movie_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Returns headers suitable for streaming video content.
  """
  def stream_headers(content_type \\ "video/mp2t") do
    [
      {"content-type", content_type},
      {"cache-control", "no-cache, no-store, must-revalidate"},
      {"pragma", "no-cache"},
      {"expires", "0"},
      {"x-accel-buffering", "no"},
      {"access-control-allow-origin", "*"},
      {"access-control-allow-methods", "GET, OPTIONS"},
      {"access-control-allow-headers", "Range, Accept-Encoding"}
    ]
  end

  @doc """
  Determines content type based on URL or filename.
  """
  def content_type_for_url(url) do
    cond do
      String.contains?(url, ".m3u8") -> "application/vnd.apple.mpegurl"
      String.contains?(url, ".ts") -> "video/mp2t"
      String.contains?(url, ".mp4") -> "video/mp4"
      String.contains?(url, ".mkv") -> "video/x-matroska"
      String.contains?(url, ".avi") -> "video/x-msvideo"
      String.contains?(url, ".webm") -> "video/webm"
      String.contains?(url, ".flv") -> "video/x-flv"
      true -> "application/octet-stream"
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("StreamProxy started with #{@cache_ttl_seconds}s TTL")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_cache()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp cache_key(url) do
    :crypto.hash(:md5, url) |> Base.encode16(case: :lower)
  end

  defp get_cached(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, data, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, data}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put_cache(key, data) do
    entry_size = byte_size(data)

    # Skip caching entries larger than the single-entry limit
    if entry_size > @max_entry_bytes do
      Logger.debug(
        "StreamProxy: Skipping cache for #{key}, entry too large (#{entry_size} bytes)"
      )
    else
      maybe_evict(entry_size)
      expires_at = System.system_time(:second) + @cache_ttl_seconds
      :ets.insert(@cache_table, {key, data, expires_at})
    end
  end

  # Evict oldest entries until we're under both the memory and entry count limits
  defp maybe_evict(incoming_size) do
    current_memory = :ets.info(@cache_table, :memory) * :erlang.system_info(:wordsize)
    current_count = :ets.info(@cache_table, :size)

    if current_memory + incoming_size > @max_cache_bytes or current_count >= @max_cache_entries do
      # Collect all entries with their expiry timestamps, sort oldest first
      entries =
        :ets.tab2list(@cache_table)
        |> Enum.sort_by(fn {_key, _data, expires_at} -> expires_at end)

      evict_until_under_limit(entries, current_memory, incoming_size, current_count)
    end
  end

  defp evict_until_under_limit([], _mem, _incoming, _count), do: :ok

  defp evict_until_under_limit([{key, data, _} | rest], mem, incoming, count) do
    if mem + incoming <= @max_cache_bytes and count < @max_cache_entries do
      :ok
    else
      freed = byte_size(data)
      :ets.delete(@cache_table, key)

      evict_until_under_limit(rest, mem - freed, incoming, count - 1)
    end
  end

  defp stream_from_url(url, cache_key) do
    # Masquerade as a common IPTV player. Upstreams increasingly gate
    # access on User-Agent (we caught a 403 on the raw default UA when
    # a provider tightened its WAF in April 2026), and the XtreamClient
    # info endpoint already sends `IPTVSmartersPlayer` — keeping the same UA
    # across every request surface keeps provider analytics /
    # allowlisting consistent across info-lookup and media playback.
    headers = [
      {"user-agent", "IPTVSmartersPlayer"},
      {"accept", "*/*"},
      {"connection", "keep-alive"}
    ]

    opts = [
      receive_timeout: @request_timeout,
      connect_options: [timeout: 10_000],
      redirect: true,
      max_redirects: 5,
      # Disable body decoding - we want raw binary for video streams
      decode_body: false
    ]

    case Req.get(url, [headers: headers] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        # Ensure body is binary (handle edge cases)
        binary_body = ensure_binary(body)

        # Cache and return the response body
        if byte_size(binary_body) > 0 do
          put_cache(cache_key, binary_body)

          Logger.debug(
            "StreamProxy: Cached #{byte_size(binary_body)} bytes for #{truncate_url(url)}"
          )
        end

        {:ok, :cached, binary_body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("StreamProxy: HTTP #{status} for #{truncate_url(url)}")
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("StreamProxy: Transport error #{inspect(reason)} for #{truncate_url(url)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Logger.error("StreamProxy: Error #{inspect(reason)} for #{truncate_url(url)}")
        {:error, reason}
    end
  end

  defp cleanup_expired_cache do
    now = System.system_time(:second)

    # Use select_delete for O(n) atomic deletion instead of foldl + individual deletes
    # Match spec: delete entries where expires_at (3rd element) < now
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    deleted_count = :ets.select_delete(@cache_table, match_spec)

    if deleted_count > 0 do
      Logger.debug("StreamProxy: Cleaned up #{deleted_count} expired cache entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp truncate_url(url) when byte_size(url) > 80 do
    String.slice(url, 0, 77) <> "..."
  end

  defp truncate_url(url), do: url

  # Ensure body is always binary
  defp ensure_binary(body) when is_binary(body), do: body
  defp ensure_binary(body) when is_map(body), do: Jason.encode!(body)
  defp ensure_binary(nil), do: ""
  defp ensure_binary(body), do: to_string(body)
end
