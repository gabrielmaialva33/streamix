defmodule Streamix.Iptv.Streaming.VodMultiplexer do
  @moduledoc """
  Serves VOD by fanning fixed-size blocks out to any number of viewers.

  `StreamMultiplexer` shares one live connection between subscribers reading
  the same position. VOD cannot work that way — viewers seek independently —
  so the unit of sharing here is the block, not the connection:

    * a viewer's `Range` is mapped onto fixed-size blocks;
    * a block already on disk is served without touching the provider;
    * a block being downloaded is awaited, so concurrent viewers collapse
      onto one upstream request (`BlockFetcher`);
    * only a genuine miss spends a `ProviderRuntime` lease.

  The result is that upstream cost scales with *distinct blocks*, not with
  viewers: the provider's `max_connections` stops being a ceiling on how many
  people can watch.
  """

  alias Plug.Conn
  alias Streamix.Iptv.Streaming.StreamErrors
  alias Streamix.Iptv.Streaming.VodMultiplexer.{BlockFetcher, BlockStore}
  alias Streamix.SafeLog

  require Logger

  @default_block_size 4 * 1_024 * 1_024
  @default_readahead_blocks 1

  @doc "Size of one cache block, in bytes."
  @spec block_size() :: pos_integer()
  def block_size do
    Application.get_env(:streamix, :vod_block_size_bytes, @default_block_size)
  end

  @doc """
  Stable identity for a piece of content.

  Signed URLs carry per-session tokens, so they cannot key a shared cache.
  Provider plus content id is stable across viewers and sessions; without
  them we fall back to hashing the URL, which still dedupes concurrent
  viewers of the very same link.
  """
  @spec content_key(keyword()) :: String.t()
  def content_key(opts) do
    provider_id = Keyword.get(opts, :provider_id)
    content_id = Keyword.get(opts, :content_id)
    media_type = Keyword.get(opts, :media_type, "movie")

    if is_integer(provider_id) and is_integer(content_id) do
      "p#{provider_id}:#{media_type}:#{content_id}"
    else
      digest =
        :sha256
        |> :crypto.hash(Keyword.get(opts, :url, ""))
        |> Base.url_encode64(padding: false)

      "url:#{digest}"
    end
  end

  @doc """
  Parses a `Range` request header into `{start, end}`.

  `end` is `:eof` for the open-ended form. Honouring the requested end is not
  optional: answering `bytes 0-1813051485/1813051486` to a client that asked
  for `bytes=0-1048575` breaks the HTTP contract, and players respond by
  discarding the response and showing a black screen.

  Only the single-range forms players actually send are understood; anything
  else is treated as a request for the whole resource.
  """
  @spec parse_range(String.t() | nil) :: {non_neg_integer(), non_neg_integer() | :eof}
  def parse_range(nil), do: {0, :eof}

  def parse_range(header) when is_binary(header) do
    case Regex.run(~r/^bytes=(\d+)-(\d*)$/, String.trim(header)) do
      [_, start, ""] -> {String.to_integer(start), :eof}
      [_, start, finish] -> {String.to_integer(start), String.to_integer(finish)}
      _ -> {0, :eof}
    end
  end

  @doc """
  Start offset of a `Range` header.

  Kept for callers that only care where playback resumes.
  """
  @spec parse_range_start(String.t() | nil) :: non_neg_integer()
  def parse_range_start(header), do: header |> parse_range() |> elem(0)

  @doc """
  Maps a byte span onto the blocks covering it.

  Each entry is `{block_index, offset_within_block, length}` — the offset
  matters only for the first block, where the viewer may start mid-block.
  """
  @spec blocks_for(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          [{non_neg_integer(), non_neg_integer(), pos_integer()}]
  def blocks_for(range_start, range_end, block_size)
      when range_end >= range_start and block_size > 0 do
    first_index = div(range_start, block_size)
    last_index = div(range_end, block_size)

    Enum.map(first_index..last_index//1, fn index ->
      block_start = index * block_size
      block_end = block_start + block_size - 1
      from = max(range_start, block_start)
      to = min(range_end, block_end)

      {index, from - block_start, to - from + 1}
    end)
  end

  def blocks_for(_range_start, _range_end, _block_size), do: []

  @doc """
  Streams `url` to `conn` through the block cache.

  Falls back to the caller's `on_miss` function when the multiplexer cannot
  serve the request — a provider with no free slot, or an upstream that does
  not support ranges — so playback degrades to the direct proxy instead of
  failing.
  """
  @spec pipe(Conn.t(), String.t(), keyword(), (Conn.t() -> Conn.t())) :: Conn.t()
  def pipe(conn, url, opts, on_miss) do
    key = content_key(Keyword.put(opts, :url, url))

    {range_start, requested_end} =
      conn |> Conn.get_req_header("range") |> List.first() |> parse_range()

    size = block_size()
    first_index = div(range_start, size)

    case fetch_block(key, first_index, url, opts) do
      {:ok, %{body: body, total_size: total_size}} when is_integer(total_size) ->
        deliver(
          conn,
          key,
          url,
          opts,
          {range_start, requested_end},
          total_size,
          {first_index, body}
        )

      {:ok, _incomplete} ->
        Logger.warning("[VodMux] upstream did not report a length; using the direct proxy")
        on_miss.(conn)

      {:error, reason} ->
        Logger.warning("[VodMux] block miss: #{SafeLog.redact_inspect(reason)}")
        on_miss.(conn)
    end
  end

  defp deliver(
         conn,
         key,
         url,
         opts,
         {range_start, requested_end},
         total_size,
         {first_index, first_body}
       ) do
    if range_start >= total_size do
      StreamErrors.halt(conn, :upstream_not_found)
    else
      range_end = resolve_range_end(requested_end, total_size)
      size = block_size()

      conn = send_range_headers(conn, range_start, range_end, total_size)
      blocks = blocks_for(range_start, range_end, size)

      # Readahead is bounded by the resource, not by this request: players ask
      # for a bounded range and immediately come back for the next one, which
      # is exactly the block worth warming.
      last_index = div(total_size - 1, size)

      Enum.reduce_while(
        blocks,
        conn,
        &write_next_block(&1, &2, {key, url, opts, last_index}, {first_index, first_body})
      )
    end
  end

  # A client asking past the end still gets a valid response bounded by the
  # resource, which is what `Content-Range` has to advertise.
  defp resolve_range_end(:eof, total_size), do: total_size - 1
  defp resolve_range_end(requested_end, total_size), do: min(requested_end, total_size - 1)

  # The first block was already fetched to learn the resource length, so it is
  # threaded through instead of being read twice.
  defp write_next_block(
         {index, offset, length},
         conn,
         {key, url, opts, last_index},
         {first_index, first_body}
       ) do
    body =
      if index == first_index do
        {:ok, %{body: first_body}}
      else
        fetch_block(key, index, url, opts)
      end

    # Warm the next block while this one is still being written to the socket,
    # so the viewer does not stall for a full round trip at every block
    # boundary.
    prefetch_next(key, index, url, opts, last_index)

    write_block(conn, body, offset, length)
  end

  defp prefetch_next(key, index, url, opts, last_index) do
    Enum.each(1..readahead_blocks()//1, fn ahead ->
      next_index = index + ahead

      if next_index <= last_index do
        size = block_size()
        range_start = next_index * size

        BlockFetcher.prefetch({key, next_index},
          url: url,
          provider_id: Keyword.get(opts, :provider_id),
          range_start: range_start,
          range_end: range_start + size - 1
        )
      end
    end)
  end

  @doc "How many blocks ahead of the current one to warm."
  @spec readahead_blocks() :: non_neg_integer()
  def readahead_blocks do
    Application.get_env(:streamix, :vod_readahead_blocks, @default_readahead_blocks)
  end

  defp write_block(conn, {:ok, %{body: body}}, offset, length) do
    slice = binary_slice(body, offset, length)

    if slice == "" do
      {:halt, conn}
    else
      case Conn.chunk(conn, slice) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end
  end

  defp write_block(conn, {:error, reason}, _offset, _length) do
    Logger.warning(
      "[VodMux] stopping stream after block error: #{SafeLog.redact_inspect(reason)}"
    )

    {:halt, conn}
  end

  defp send_range_headers(conn, range_start, range_end, total_size) do
    conn
    |> Conn.put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{total_size}")
    |> Conn.put_resp_header("accept-ranges", "bytes")
    |> Conn.put_resp_header("content-type", "video/mp4")
    |> Conn.put_resp_header("cache-control", "no-cache, no-store")
    |> Conn.put_resp_header("access-control-allow-origin", "*")
    |> Conn.put_resp_header(
      "access-control-expose-headers",
      "Content-Length, Content-Range, Accept-Ranges"
    )
    |> Conn.send_chunked(206)
  end

  defp fetch_block(key, index, url, opts) do
    block_key = {key, index}

    case BlockStore.read(block_key) do
      {:ok, body} ->
        {:ok, %{body: body, total_size: BlockStore.total_size(key)}}

      :miss ->
        size = block_size()
        range_start = index * size

        block_key
        |> BlockFetcher.await(
          url: url,
          provider_id: Keyword.get(opts, :provider_id),
          range_start: range_start,
          range_end: range_start + size - 1
        )
        |> retry_from_store(block_key, key)
    end
  end

  # A fetcher that finished and was reaped between our lookup and our call has
  # still done the work — the bytes are on disk.
  defp retry_from_store({:error, :fetcher_gone}, block_key, key) do
    case BlockStore.read(block_key) do
      {:ok, body} -> {:ok, %{body: body, total_size: BlockStore.total_size(key)}}
      :miss -> {:error, :fetcher_gone}
    end
  end

  defp retry_from_store(result, _block_key, _key), do: result
end
