defmodule Streamix.Iptv.Streaming.VodMultiplexer.BlockStore do
  @moduledoc """
  Disk-backed LRU cache for fixed-size VOD blocks.

  The multiplexer fans one upstream fetch out to every viewer of a block,
  which already collapses concurrent demand. This store is what removes the
  upstream from the picture entirely on replay: once a block is on disk, any
  number of later viewers are served without touching the provider.

  The process only owns the index. Callers do their own file I/O so a slow
  disk never serializes behind a single GenServer.

  The blocks live on a volume that outlives deploys, while the index lives in
  ETS. On boot the store therefore rebuilds the index from the files on disk
  (oldest modification first in line for eviction) and trims it to the
  budget; without that, every restart left the previous blocks both
  unreachable and uncounted, and the cache grew past its budget forever.
  """

  use GenServer

  require Logger

  alias Streamix.SafeLog

  @table __MODULE__.Index
  @meta_table __MODULE__.Meta
  @default_max_bytes 20 * 1_024 * 1_024 * 1_024

  @type key :: {String.t(), non_neg_integer()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the path of a cached block and marks it as recently used.

  The caller reads the file itself. A path that vanished between the lookup
  and the read is reported as a miss by `read/1`.
  """
  @spec lookup(key()) :: {:ok, Path.t()} | :miss
  def lookup(key) do
    path = path_for(key)

    case :ets.lookup(@table, path) do
      [{^path, _size, _accessed_at}] ->
        GenServer.cast(__MODULE__, {:touch, path})
        {:ok, path}

      [] ->
        :miss
    end
  end

  @doc "Reads a cached block, treating a concurrently evicted file as a miss."
  @spec read(key()) :: {:ok, binary()} | :miss
  def read(key) do
    with {:ok, path} <- lookup(key),
         {:ok, data} <- File.read(path) do
      {:ok, data}
    else
      :miss -> :miss
      {:error, _reason} -> :miss
    end
  end

  @doc """
  Stores a block, replacing any previous copy.

  Writing to a temporary file and renaming keeps readers from ever observing
  a partially written block.
  """
  @spec put(key(), binary()) :: :ok | {:error, term()}
  def put(key, data) when is_binary(data) do
    path = path_for(key)
    temporary_path = path <> ".partial"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary_path, data),
         :ok <- File.rename(temporary_path, path) do
      register(path, byte_size(data))
    else
      {:error, reason} = error ->
        File.rm(temporary_path)
        Logger.warning("[VodMux] could not cache block", reason: SafeLog.redact_inspect(reason))
        error
    end
  end

  # The writer indexes its own block, so a read right after `put/2` hits, and
  # only hands the size change to the process, which owns accounting and
  # eviction. A writer never waits behind the index, not even while the
  # boot-time reindex is still trimming a large backlog.
  defp register(path, size) do
    previous_size =
      case :ets.lookup(@table, path) do
        [{^path, previous_size, _accessed_at}] -> previous_size
        [] -> 0
      end

    :ets.insert(@table, {path, size, monotonic_now()})
    GenServer.cast(__MODULE__, {:account, size - previous_size})
  end

  @doc "Total bytes currently held on disk."
  @spec size_bytes() :: non_neg_integer()
  def size_bytes, do: GenServer.call(__MODULE__, :size_bytes)

  @doc """
  Remembers how long a resource is, so later readers can answer a `206`
  without spending an upstream request just to learn the length.
  """
  @spec put_total_size(String.t(), pos_integer()) :: :ok
  def put_total_size(content_key, total_size) when is_integer(total_size) and total_size > 0 do
    :ets.insert(@meta_table, {content_key, total_size})
    persist_total_size(content_key, total_size)
    :ok
  end

  @spec total_size(String.t()) :: pos_integer() | nil
  def total_size(content_key) do
    case :ets.lookup(@meta_table, content_key) do
      [{^content_key, total_size}] ->
        total_size

      [] ->
        # ETS is per-boot, but the cached blocks outlive deploys. Without
        # the length the multiplexer cannot answer a 206, so it falls back
        # to the direct proxy — and if the upstream has meanwhile stopped
        # reporting a length (expired credentials, a CDN-cached error page),
        # the resource becomes unplayable even though its blocks are right
        # there on disk. Recovering it from the sidecar keeps a restart from
        # throwing away something we already know.
        recover_total_size(content_key)
    end
  end

  defp persist_total_size(content_key, total_size) do
    path = total_size_path_for(content_key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Integer.to_string(total_size))
    end
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[VodMux] could not persist total size",
          reason: SafeLog.redact_inspect(reason)
        )

        :ok
    end
  end

  defp recover_total_size(content_key) do
    with {:ok, contents} <- File.read(total_size_path_for(content_key)),
         {total_size, ""} <- Integer.parse(String.trim(contents)),
         true <- total_size > 0 do
      :ets.insert(@meta_table, {content_key, total_size})
      total_size
    else
      _ -> nil
    end
  end

  @doc false
  @spec total_size_path_for(String.t()) :: Path.t()
  def total_size_path_for(content_key) do
    digest = digest_for(content_key)

    Path.join([
      cache_dir(),
      binary_part(digest, 0, 2),
      binary_part(digest, 2, 2),
      "#{digest}.size"
    ])
  end

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Rebuilds the index from the blocks on disk and trims it to the budget.

  Runs once after boot. Blocks already indexed keep their place; files left
  half-written by a crash are removed.
  """
  @spec reindex() :: :ok
  def reindex, do: GenServer.call(__MODULE__, :reindex, :infinity)

  @doc "Absolute path a block would occupy."
  @spec path_for(key()) :: Path.t()
  def path_for({content_key, block_index}) do
    digest = digest_for(content_key)

    # Two levels of fan-out keep directory sizes reasonable once a large
    # catalog has been through the cache.
    Path.join([
      cache_dir(),
      binary_part(digest, 0, 2),
      binary_part(digest, 2, 2),
      "#{digest}.#{block_index}"
    ])
  end

  defp digest_for(content_key) do
    :sha256
    |> :crypto.hash(content_key)
    |> Base.url_encode64(padding: false)
  end

  @spec cache_dir() :: Path.t()
  def cache_dir do
    Application.get_env(:streamix, :vod_cache_dir) ||
      Path.join(System.tmp_dir!(), "streamix-vod-cache")
  end

  @spec max_bytes() :: pos_integer()
  def max_bytes do
    Application.get_env(:streamix, :vod_cache_max_bytes, @default_max_bytes)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@meta_table, [:named_table, :public, :set, read_concurrency: true])
    File.mkdir_p(cache_dir())

    {:ok, %{total_bytes: 0}, {:continue, :reindex}}
  end

  @impl true
  def handle_continue(:reindex, state), do: {:noreply, adopt_disk_blocks(state)}

  @impl true
  def handle_call(:reindex, _from, state), do: {:reply, :ok, adopt_disk_blocks(state)}

  def handle_call(:size_bytes, _from, state), do: {:reply, state.total_bytes, state}

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@meta_table)
    File.rm_rf(cache_dir())
    File.mkdir_p(cache_dir())

    {:reply, :ok, %{state | total_bytes: 0}}
  end

  @impl true
  def handle_cast({:account, delta}, state) do
    state =
      %{state | total_bytes: max(state.total_bytes + delta, 0)}
      |> evict_until_within_budget()

    {:noreply, state}
  end

  def handle_cast({:touch, path}, state) do
    case :ets.lookup(@table, path) do
      [{^path, size, _accessed_at}] ->
        :ets.insert(@table, {path, size, monotonic_now()})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  defp evict_until_within_budget(state) do
    budget = max_bytes()

    if state.total_bytes <= budget do
      state
    else
      case oldest_entry() do
        nil ->
          state

        {path, size, _accessed_at} ->
          :ets.delete(@table, path)
          File.rm(path)

          evict_until_within_budget(%{state | total_bytes: max(state.total_bytes - size, 0)})
      end
    end
  end

  defp oldest_entry do
    :ets.foldl(
      fn {_path, _size, accessed_at} = entry, oldest ->
        case oldest do
          nil -> entry
          {_, _, oldest_at} when accessed_at < oldest_at -> entry
          _ -> oldest
        end
      end,
      nil,
      @table
    )
  end

  # Indexes every block file not indexed yet, ranked by modification time so
  # the oldest go first, then drops the oldest in one pass until the store
  # fits its budget. One sorted pass instead of evict_until_within_budget/1,
  # which scans the whole index per eviction and would crawl through a large
  # backlog.
  defp adopt_disk_blocks(state) do
    now = monotonic_now()
    now_unix = System.os_time(:second)

    adopted =
      for path <- Path.wildcard(Path.join(cache_dir(), "*/*/*")),
          block_file?(path, now_unix),
          {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
            [File.stat(path, time: :posix)],
          :ets.insert_new(@table, {path, size, now - (now_unix - mtime) * 1_000_000}),
          do: size

    total = trim_to_budget(state.total_bytes + Enum.sum(adopted), max_bytes())

    if adopted != [] do
      Logger.info(
        "[VodMux] block cache reindexed: #{length(adopted)} blocks, #{total} bytes kept"
      )
    end

    %{state | total_bytes: total}
  end

  defp trim_to_budget(total, budget) when total <= budget, do: total

  defp trim_to_budget(total, budget) do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_path, _size, accessed_at} -> accessed_at end)
    |> Enum.reduce_while(total, fn
      _entry, remaining when remaining <= budget ->
        {:halt, remaining}

      {path, size, _accessed_at}, remaining ->
        :ets.delete(@table, path)
        File.rm(path)
        {:cont, remaining - size}
    end)
  end

  # Block files are "<digest>.<index>". Sidecars ("<digest>.size") stay; a
  # ".partial" older than a minute was left by a crash mid-write.
  defp block_file?(path, now_unix) do
    case Path.extname(path) do
      ".size" ->
        false

      ".partial" ->
        with {:ok, %File.Stat{mtime: mtime}} when now_unix - mtime > 60 <-
               File.stat(path, time: :posix) do
          File.rm(path)
        end

        false

      "." <> index ->
        match?({_, ""}, Integer.parse(index))

      _other ->
        false
    end
  end

  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
