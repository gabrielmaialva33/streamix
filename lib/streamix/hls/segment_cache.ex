defmodule Streamix.Hls.SegmentCache do
  @moduledoc """
  A short, shared, bounded cache of HLS media responses (segments), with
  single-flight.

  Keyed by the upstream segment URL, the first request for a segment runs the
  upstream fetch and every concurrent request for that URL waits for it. That
  is what lets a gateway prefetch the next few segments of a playback (the
  player's request then joins the fetch already in flight, or finds it done)
  and what makes N viewers of one live channel cost one upstream fetch per
  segment. A complete `200` media response is kept for `ttl_ms` (default
  45 s — long enough for a player to reach a prefetched segment, a few target
  durations of a live playlist) and then expires.

  Only whole `200` media bodies are stored: range requests, `HEAD`, errors and
  playlists never are. Memory is bounded twice: an entry larger than
  `max_entry_bytes` (16 MiB) is served but not kept, and when the total
  passes `max_bytes` (128 MiB) the oldest entries are dropped first. Expired
  entries are swept every few seconds.

  This is not an accelerator: each segment is fetched once, over one ordinary
  connection, as a player's own forward buffer would. Configuration lives
  under `config :streamix, :hls_segment_cache`; the cache is node-local.
  """

  use GenServer

  @entries :hls_segment_cache
  @order :hls_segment_cache_order
  @playlist_type "application/vnd.apple.mpegurl"
  @sweep_interval_ms 5_000
  @max_waiters 512

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the cached response for `key`, or runs `fetch` (a zero-arity
  function returning `{:ok, response}` or `{:error, reason}`) once for every
  concurrent caller of that key, caching a cacheable result.

  `:timeout` bounds how long a caller waits for the shared fetch.
  """
  @spec fetch(String.t(), (-> {:ok, map()} | {:error, term()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch(key, fetch, opts \\ []) when is_binary(key) and is_function(fetch, 0) do
    case lookup(key) do
      {:hit, response} ->
        {:ok, response}

      :miss ->
        timeout = Keyword.get(opts, :timeout, 60_000)
        GenServer.call(__MODULE__, {:fetch, key, fetch, timeout}, timeout + 5_000)
    end
  end

  @doc "Whether a fresh response for `key` is cached."
  @spec cached?(String.t()) :: boolean()
  def cached?(key), do: match?({:hit, _response}, lookup(key))

  @doc "Total bytes currently cached."
  @spec bytes() :: non_neg_integer()
  def bytes, do: GenServer.call(__MODULE__, :bytes)

  @doc false
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_opts) do
    :ets.new(@entries, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@order, [:named_table, :ordered_set, :protected])
    schedule_sweep()
    {:ok, %{pending: %{}, tasks: %{}, bytes: 0, seq: 0}}
  end

  @impl true
  def handle_call({:fetch, key, fetch, timeout}, from, state) do
    case {lookup(key), state.pending[key]} do
      {{:hit, response}, _pending} ->
        {:reply, {:ok, response}, state}

      {:miss, %{waiters: waiters}} when length(waiters) >= @max_waiters ->
        {:reply, {:error, :provider_capacity_exhausted}, state}

      {:miss, %{waiters: waiters}} ->
        {:noreply, put_in(state.pending[key].waiters, [from | waiters])}

      {:miss, nil} ->
        task = Task.Supervisor.async_nolink(Streamix.TaskSupervisor, fetch)
        timer = Process.send_after(self(), {:deadline, task.ref}, timeout)

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, key, %{waiters: [from], task: task, timer: timer}),
             tasks: Map.put(state.tasks, task.ref, key)
         }}
    end
  end

  def handle_call(:bytes, _from, state), do: {:reply, state.bytes, state}

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@entries)
    :ets.delete_all_objects(@order)
    {:reply, :ok, %{state | bytes: 0}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, finish(state, ref, {:error, :upstream_unavailable})}

  def handle_info({:deadline, ref}, state) do
    if key = state.tasks[ref], do: Task.shutdown(state.pending[key].task, :brutal_kill)
    {:noreply, finish(state, ref, {:error, :upstream_timeout})}
  end

  def handle_info(:sweep, state) do
    schedule_sweep()
    now = now()

    expired =
      :ets.select(@entries, [{{:"$1", :_, :"$2", :_, :_}, [{:"=<", :"$2", now}], [:"$1"]}])

    {:noreply, Enum.reduce(expired, state, &delete/2)}
  end

  defp finish(state, ref, result) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        state

      {key, tasks} ->
        {pending, pending_map} = Map.pop(state.pending, key)
        Process.cancel_timer(pending.timer)
        result = normalize(result)
        # Stored before anyone is answered, so a caller that hears back can
        # already find the segment cached.
        state = store(%{state | tasks: tasks, pending: pending_map}, key, result)
        Enum.each(pending.waiters, &GenServer.reply(&1, result))
        state
    end
  end

  defp normalize({:ok, %{status: _, body: _, headers: _}} = result), do: result
  defp normalize({:error, _reason} = error), do: error
  defp normalize(_other), do: {:error, :upstream_unavailable}

  defp store(state, key, {:ok, %{status: 200, body: body, headers: headers} = response})
       when is_binary(body) do
    size = byte_size(body)

    if cacheable?(headers, size) do
      state = delete(key, state)
      seq = state.seq + 1
      :ets.insert(@entries, {key, response, now() + ttl_ms(), size, seq})
      :ets.insert(@order, {seq, key})
      evict_to_bound(%{state | seq: seq, bytes: state.bytes + size})
    else
      state
    end
  end

  defp store(state, _key, _result), do: state

  defp cacheable?(headers, size) do
    type = headers |> Map.get("content-type", []) |> List.first()

    type != @playlist_type and size > 0 and size <= config(:max_entry_bytes, 16 * 1024 * 1024) and
      ttl_ms() > 0
  end

  # Oldest first: the order table is keyed by insertion sequence.
  defp evict_to_bound(state) do
    with true <- state.bytes > config(:max_bytes, 128 * 1024 * 1024),
         seq when is_integer(seq) <- :ets.first(@order),
         [{^seq, key}] <- :ets.lookup(@order, seq) do
      key |> delete(state) |> evict_to_bound()
    else
      _ -> state
    end
  end

  defp ttl_ms, do: config(:ttl_ms, 45_000)

  defp delete(key, state) do
    case :ets.lookup(@entries, key) do
      [{^key, _response, _expires_at, size, seq}] ->
        :ets.delete(@entries, key)
        :ets.delete(@order, seq)
        %{state | bytes: state.bytes - size}

      [] ->
        state
    end
  end

  defp lookup(key) do
    case :ets.lookup(@entries, key) do
      [{^key, response, expires_at, _size, _seq}] ->
        if expires_at > now(), do: {:hit, response}, else: :miss

      [] ->
        :miss
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:streamix, :hls_segment_cache, []), key, default)

  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
