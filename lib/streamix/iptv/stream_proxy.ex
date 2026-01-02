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

  alias Streamix.Iptv.Gindex.UrlCache

  @cache_table :stream_proxy_cache
  # 5 minutes cache
  @cache_ttl_seconds 300
  # Cleanup every minute
  @cleanup_interval_ms 60_000
  # 30 seconds timeout
  @request_timeout 30_000

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
    expires_at = System.system_time(:second) + @cache_ttl_seconds
    :ets.insert(@cache_table, {key, data, expires_at})
  end

  defp stream_from_url(url, cache_key) do
    headers = [
      {"user-agent", "Streamix/1.0"},
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

    expired_keys =
      :ets.foldl(
        fn {key, _data, expires_at}, acc ->
          if expires_at < now, do: [key | acc], else: acc
        end,
        [],
        @cache_table
      )

    Enum.each(expired_keys, &:ets.delete(@cache_table, &1))

    unless Enum.empty?(expired_keys) do
      Logger.debug("StreamProxy: Cleaned up #{Enum.count(expired_keys)} expired cache entries")
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
