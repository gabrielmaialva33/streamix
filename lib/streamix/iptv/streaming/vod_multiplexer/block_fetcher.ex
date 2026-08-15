defmodule Streamix.Iptv.Streaming.VodMultiplexer.BlockFetcher do
  @moduledoc """
  Single-flight download of one fixed-size VOD block.

  One process owns each in-flight `{content_key, block_index}`. Viewers that
  ask for a block already being fetched wait on that same process instead of
  opening their own upstream connection, so a hundred viewers of one movie
  cost the provider exactly one request per block.

  The download runs in `handle_continue/2`, so concurrent `await/2` calls
  queue in the mailbox and are all answered from the single result.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.Streaming.VodMultiplexer.BlockStore
  alias Streamix.SafeLog

  @registry Streamix.StreamRegistry
  @receive_timeout 30_000
  @await_timeout 45_000
  # How long a finished fetcher stays around to answer late subscribers
  # before the block store takes over.
  @linger_ms 5_000

  @type key :: BlockStore.key()

  @doc """
  Downloads `key` once and returns its bytes to every concurrent caller.

  `total_size` carries the full resource length parsed from `Content-Range`,
  which the reader needs to answer the viewer with a correct `206`.

  `:capacity_exhausted` means the provider had no free slot; the caller
  decides whether to fall back to a direct stream or surface the error.
  """
  @spec await(key(), keyword()) ::
          {:ok, %{body: binary(), total_size: pos_integer() | nil}} | {:error, term()}
  def await(key, opts) do
    with {:ok, pid} <- start_or_lookup(key, opts) do
      GenServer.call(pid, :await, @await_timeout)
    end
  catch
    :exit, {:timeout, _} -> {:error, :block_timeout}
    # The fetcher stops as soon as it has answered everyone, so a caller can
    # legitimately find a dead process between lookup and call.
    :exit, {:noproc, _} -> {:error, :fetcher_gone}
  end

  @doc false
  def start_link(args) do
    key = Keyword.fetch!(args, :key)
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, name_for(key)}})
  end

  defp start_or_lookup(key, opts) do
    args = Keyword.put(opts, :key, key)

    case DynamicSupervisor.start_child(
           Streamix.Iptv.Streaming.VodMultiplexer.Supervisor,
           {__MODULE__, args}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        case Registry.lookup(@registry, name_for(key)) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, reason}
        end
    end
  end

  defp name_for({content_key, block_index}), do: {:vod_block, content_key, block_index}

  @impl true
  def init(args) do
    state = %{
      key: Keyword.fetch!(args, :key),
      url: Keyword.fetch!(args, :url),
      provider_id: Keyword.get(args, :provider_id),
      range_start: Keyword.fetch!(args, :range_start),
      range_end: Keyword.fetch!(args, :range_end),
      result: nil,
      pending: []
    }

    {:ok, state, {:continue, :download}}
  end

  @impl true
  def handle_continue(:download, state) do
    result = download(state)

    Enum.each(state.pending, &GenServer.reply(&1, result))

    # `handle_continue/2` runs before any queued `:await`, so callers that
    # arrived while the download was in flight are still sitting in the
    # mailbox. Linger instead of stopping, otherwise they would all exit with
    # `:normal` on a call to a dead process. The idle timeout reaps us once
    # the last late subscriber has been answered.
    {:noreply, %{state | result: result, pending: []}, @linger_ms}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | pending: [from | state.pending]}}
  end

  def handle_call(:await, _from, state), do: {:reply, state.result, state, @linger_ms}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state, @linger_ms}

  defp download(state) do
    case ProviderRuntime.acquire(state.provider_id, :vod, self()) do
      {:ok, lease} ->
        try do
          request(state)
        after
          ProviderRuntime.release(lease)
        end

      {:error, :capacity_exhausted} ->
        {:error, :capacity_exhausted}
    end
  end

  defp request(state) do
    range = "bytes=#{state.range_start}-#{state.range_end}"
    request = Finch.build(:get, state.url, [{"range", range}, {"connection", "close"}])

    case Finch.request(request, Streamix.StreamFinch,
           receive_timeout: @receive_timeout,
           pool_timeout: 5_000
         ) do
      {:ok, %{status: status, body: body, headers: headers}} when status in [200, 206] ->
        total_size = total_size(headers, status, body)
        store(state, body)
        maybe_store_total_size(state, total_size)

        {:ok, %{body: body, total_size: total_size}}

      {:ok, %{status: 416}} ->
        # Past end of file — a legitimate answer for the last block.
        {:ok, %{body: "", total_size: BlockStore.total_size(elem(state.key, 0))}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[VodMux] block fetch failed: #{SafeLog.redact_inspect(reason)}")
        {:error, reason}
    end
  end

  # `Content-Range: bytes 0-4194303/1234567890` is the only place the upstream
  # tells us how long the movie is. A plain 200 means it ignored the Range, so
  # the body itself is the whole resource.
  defp total_size(headers, 206, _body) do
    with {_name, value} <- List.keyfind(headers, "content-range", 0, nil),
         [_, total] <- String.split(value, "/", parts: 2),
         {total_size, ""} <- Integer.parse(total) do
      total_size
    else
      _ -> nil
    end
  end

  defp total_size(_headers, 200, body), do: byte_size(body)

  defp maybe_store_total_size(_state, nil), do: :ok

  defp maybe_store_total_size(state, total_size) do
    BlockStore.put_total_size(elem(state.key, 0), total_size)
  end

  # A 200 means the upstream ignored our Range and is sending the whole file;
  # caching that under a block key would corrupt every later read.
  defp store(%{range_start: range_start, range_end: range_end} = state, body)
       when byte_size(body) <= range_end - range_start + 1 do
    BlockStore.put(state.key, body)
  end

  defp store(_state, _body), do: :ok
end
