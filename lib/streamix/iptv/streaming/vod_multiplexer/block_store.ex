defmodule Streamix.Iptv.Streaming.VodMultiplexer.BlockStore do
  @moduledoc """
  Disk-backed LRU cache for fixed-size VOD blocks.

  The multiplexer fans one upstream fetch out to every viewer of a block,
  which already collapses concurrent demand. This store is what removes the
  upstream from the picture entirely on replay: once a block is on disk, any
  number of later viewers are served without touching the provider.

  The process only owns the index. Callers do their own file I/O so a slow
  disk never serializes behind a single GenServer.
  """

  use GenServer

  require Logger

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
    case :ets.lookup(@table, key) do
      [{^key, path, _size, _accessed_at}] ->
        GenServer.cast(__MODULE__, {:touch, key})
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
      GenServer.call(__MODULE__, {:register, key, path, byte_size(data)})
    else
      {:error, reason} = error ->
        File.rm(temporary_path)
        Logger.warning("[VodMux] could not cache block: #{inspect(reason)}")
        error
    end
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
        Logger.warning("[VodMux] could not persist total size: #{inspect(reason)}")
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

    {:ok, %{total_bytes: 0}}
  end

  @impl true
  def handle_call({:register, key, path, size}, _from, state) do
    previous_size =
      case :ets.lookup(@table, key) do
        [{^key, _path, size, _accessed_at}] -> size
        [] -> 0
      end

    :ets.insert(@table, {key, path, size, monotonic_now()})

    state =
      %{state | total_bytes: state.total_bytes - previous_size + size}
      |> evict_until_within_budget()

    {:reply, :ok, state}
  end

  def handle_call(:size_bytes, _from, state), do: {:reply, state.total_bytes, state}

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@meta_table)
    File.rm_rf(cache_dir())
    File.mkdir_p(cache_dir())

    {:reply, :ok, %{state | total_bytes: 0}}
  end

  @impl true
  def handle_cast({:touch, key}, state) do
    case :ets.lookup(@table, key) do
      [{^key, path, size, _accessed_at}] ->
        :ets.insert(@table, {key, path, size, monotonic_now()})

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

        {key, path, size, _accessed_at} ->
          :ets.delete(@table, key)
          File.rm(path)

          evict_until_within_budget(%{state | total_bytes: max(state.total_bytes - size, 0)})
      end
    end
  end

  defp oldest_entry do
    :ets.foldl(
      fn {_key, _path, _size, accessed_at} = entry, oldest ->
        case oldest do
          nil -> entry
          {_, _, _, oldest_at} when accessed_at < oldest_at -> entry
          _ -> oldest
        end
      end,
      nil,
      @table
    )
  end

  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
