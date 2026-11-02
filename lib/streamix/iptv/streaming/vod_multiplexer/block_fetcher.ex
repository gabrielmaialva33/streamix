defmodule Streamix.Iptv.Streaming.VodMultiplexer.BlockFetcher do
  @moduledoc """
  Single-flight download of one fixed-size VOD block.

  One process owns each in-flight `{content_key, block_index}`. Viewers that
  ask for a block already being fetched share that same process instead of
  opening their own upstream connection, so a hundred viewers of one movie
  cost the provider exactly one request per block.

  Readers can consume a block two ways:

    * `subscribe/2` streams it: the resource length as soon as the upstream
      answers, then every chunk as it arrives. The viewer's first frame then
      waits for the provider's first bytes, not for a whole block — with
      4 MiB blocks and a provider doing 2–3 Mbit/s that is the difference
      between well under a second and 10–15 s of black screen.
    * `await/2` returns the finished block in one piece.

  A connection that drops mid-block is resumed from the first missing byte,
  so a provider that closes sockets under load costs a reconnect instead of
  the viewer's stream.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.Streaming.RedirectResolver
  alias Streamix.Iptv.Streaming.UpstreamLease
  alias Streamix.Iptv.Streaming.UpstreamPolicy
  alias Streamix.Iptv.Streaming.VodMultiplexer.BlockStore
  alias Streamix.SafeLog

  @registry Streamix.StreamRegistry
  @receive_timeout 30_000
  # Hard ceiling on one block download. `@receive_timeout` only bounds the gap
  # between two chunks, so a slow-but-alive upstream can hold the connection
  # far longer than any viewer is willing to wait. Past this point nobody is
  # listening anymore: the player has given up, and the only thing the fetch
  # still does is occupy a provider slot and eat bandwidth that the viewer's
  # next attempt needs. Keep it under the player's own 30 s load timeout so
  # subscribers get a real answer instead of timing out on us.
  @download_deadline_ms 25_000
  # Must stay above @download_deadline_ms — the fetcher is guaranteed to
  # answer by then, and waiting longer only delays the caller's own failover.
  @await_timeout 28_000
  # How long a finished fetcher stays around to answer late subscribers
  # before the block store takes over.
  @linger_ms 5_000
  # A failed fetch lingers only long enough to drain the subscribers already
  # queued in the mailbox. Holding the failure any longer would make every
  # later reader inherit it instead of getting a fresh attempt.
  @error_linger_ms 50
  # Reconnects after the upstream drops the socket mid-block. Each one asks
  # only for the bytes still missing, and all of them share the deadline.
  @max_resumes 2

  @type key :: BlockStore.key()
  @type event ::
          {:head, pos_integer() | nil}
          | {:data, binary()}
          | {:done, pos_integer() | nil}
          | {:error, term()}

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

  @doc """
  Streams `key` to the calling process as it downloads.

  Returns `{:streaming, ref, snapshot}` while the download is in flight:
  `snapshot` holds the length (if the upstream already sent it) and every
  byte received so far, and the rest arrives as `{:vod_block, ref, event}`
  messages — `{:head, total_size}`, then `{:data, binary}` chunks, ending in
  `{:done, total_size}` or `{:error, reason}`.

  A fetcher that already finished answers with `{:finished, result}`, in the
  same shape `await/2` returns.

  Call `unsubscribe/1` with the ref to stop early; the download itself goes
  on for the other readers and for the cache.
  """
  @spec subscribe(key(), keyword()) ::
          {:streaming, reference(), %{total_size: pos_integer() | nil, data: binary()}}
          | {:finished, {:ok, map()} | {:error, term()}}
          | {:error, term()}
  def subscribe(key, opts) do
    with {:ok, pid} <- start_or_lookup(key, opts) do
      case GenServer.call(pid, {:subscribe, self()}, @await_timeout) do
        {:streaming, ref, _snapshot} = streaming ->
          Process.put({__MODULE__, ref}, pid)
          streaming

        other ->
          other
      end
    end
  catch
    :exit, {:timeout, _} -> {:error, :block_timeout}
    :exit, {:noproc, _} -> {:error, :fetcher_gone}
  end

  @doc "Stops the messages of a `subscribe/2` and drops any still queued."
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) when is_reference(ref) do
    case Process.get({__MODULE__, ref}) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:unsubscribe, ref})
      nil -> :ok
    end

    Process.delete({__MODULE__, ref})
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:vod_block, ^ref, _event} -> flush(ref)
    after
      0 -> :ok
    end
  end

  @doc """
  Starts a block download without waiting for it.

  The fetcher begins downloading from `handle_continue/2`, so simply starting
  it is enough to warm the next block while the current one is still being
  written to the viewer. Best-effort by design: a block that is already
  cached, already in flight, or that cannot get a lease right now is simply
  not prefetched.
  """
  @spec prefetch(key(), keyword()) :: :ok
  def prefetch(key, opts) do
    case BlockStore.lookup(key) do
      {:ok, _path} ->
        :ok

      :miss ->
        _ = start_or_lookup(key, opts)
        :ok
    end
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
      domain_policy: Keyword.get(args, :domain_policy),
      provider_id: Keyword.get(args, :provider_id),
      range_start: Keyword.fetch!(args, :range_start),
      range_end: Keyword.fetch!(args, :range_end),
      result: nil,
      pending: [],
      subscribers: %{},
      total_size: nil,
      chunks: [],
      task: nil,
      deadline: nil
    }

    {:ok, state, {:continue, :download}}
  end

  # The download runs in a task purely so it can be killed. Finch's timeouts
  # bound each receive, not the request as a whole, and a provider that
  # trickles bytes keeps the request inside `prim_inet:recv0` for as long as
  # it likes — which strands the lease acquired in `download/2`, because the
  # `after` that releases it never runs. Killing the task closes the socket
  # and the lease comes back through the owner's `:DOWN`.
  @impl true
  def handle_continue(:download, state) do
    fetcher = self()
    job = Map.take(state, [:key, :url, :domain_policy, :provider_id, :range_start, :range_end])
    task = Task.Supervisor.async_nolink(Streamix.TaskSupervisor, fn -> download(job, fetcher) end)
    deadline = Process.send_after(self(), :deadline, download_deadline_ms())

    {:noreply, %{state | task: task, deadline: deadline}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | pending: [from | state.pending]}}
  end

  def handle_call(:await, _from, state),
    do: {:reply, state.result, state, linger_for(state.result)}

  def handle_call({:subscribe, pid}, _from, %{result: nil} = state) do
    ref = Process.monitor(pid)
    snapshot = %{total_size: state.total_size, data: received(state)}

    {:reply, {:streaming, ref, snapshot}, put_in(state.subscribers[ref], pid)}
  end

  def handle_call({:subscribe, _pid}, _from, state),
    do: {:reply, {:finished, state.result}, state, linger_for(state.result)}

  @impl true
  def handle_cast({:unsubscribe, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}, idle_timeout(state)}
  end

  @impl true
  def handle_info({:block_head, total_size}, %{result: nil} = state) do
    broadcast(state, {:head, total_size})
    {:noreply, %{state | total_size: total_size}}
  end

  def handle_info({:block_data, data}, %{result: nil} = state) do
    broadcast(state, {:data, data})
    {:noreply, %{state | chunks: [data | state.chunks]}}
  end

  def handle_info({ref, outcome}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("[VodMux] block download crashed: #{SafeLog.redact_inspect(reason)}")
    finish(state, {:error, :block_download_crashed})
  end

  def handle_info(:deadline, %{result: nil, task: task} = state) do
    Task.shutdown(task, :brutal_kill)

    Logger.warning(
      "[VodMux] abandoning block download after #{download_deadline_ms()}ms; releasing the provider slot"
    )

    finish(state, {:error, :block_deadline_exceeded})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}, idle_timeout(state)}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state, idle_timeout(state)}

  defp finish(state, outcome) do
    if state.deadline, do: Process.cancel_timer(state.deadline)

    result = result_for(state, outcome)
    Enum.each(state.pending, &GenServer.reply(&1, result))

    case result do
      {:ok, %{total_size: total_size}} -> broadcast(state, {:done, total_size})
      {:error, reason} -> broadcast(state, {:error, reason})
    end

    Enum.each(state.subscribers, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

    # Callers that arrived while the download was in flight may still be
    # sitting in the mailbox. Linger instead of stopping, otherwise they would
    # all exit with `:normal` on a call to a dead process. The idle timeout
    # reaps us once the last late subscriber has been answered.
    state = %{state | result: result, pending: [], subscribers: %{}, chunks: [], task: nil}
    {:noreply, state, linger_for(result)}
  end

  defp result_for(state, {:ok, status}) do
    body = received(state)
    store(state, status, body)
    maybe_store_total_size(state, state.total_size)

    {:ok, %{body: body, total_size: state.total_size}}
  end

  defp result_for(_state, {:error, reason}), do: {:error, reason}

  defp received(state), do: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp broadcast(state, event) do
    Enum.each(state.subscribers, fn {ref, pid} -> send(pid, {:vod_block, ref, event}) end)
  end

  defp idle_timeout(%{result: nil}), do: :infinity
  defp idle_timeout(state), do: linger_for(state.result)

  defp linger_for({:ok, _payload}), do: @linger_ms
  defp linger_for(_error), do: @error_linger_ms

  # Configurable so tests can exercise the deadline without burning 25 s.
  defp download_deadline_ms do
    Application.get_env(:streamix, :vod_block_deadline_ms, @download_deadline_ms)
  end

  defp download(job, fetcher) do
    case UpstreamLease.acquire(job.provider_id, :vod, self()) do
      {:ok, lease} ->
        try do
          request(job, fetcher)
        after
          ProviderRuntime.release(lease)
        end

      {:error, :capacity_exhausted} ->
        {:error, :capacity_exhausted}
    end
  end

  defp request(job, fetcher) do
    case resolve(job.url, job.domain_policy) do
      {:ok, final_url} ->
        progress = %{fetcher: fetcher, offset: job.range_start, head_sent?: false, status: nil}
        fetch_range(job, final_url, progress, @max_resumes)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Xtream hands out a 302 chain (vauth → … → deliver) and Finch does not
  # follow redirects, so the chain has to be walked first — exactly like
  # `VodProxy` does. `RedirectResolver` caches the outcome, so this is cheap
  # for the blocks that follow.
  defp resolve(url, policy) do
    RedirectResolver.resolve(url, domain_policy: policy)
  end

  defp fetch_range(job, final_url, progress, resumes_left) do
    headers =
      UpstreamPolicy.headers(
        final_url,
        [{"range", "bytes=#{progress.offset}-#{job.range_end}"}, {"connection", "close"}],
        job.domain_policy
      )

    request = Finch.build(:get, final_url, headers)
    acc = Map.merge(progress, %{job: job, outcome: nil})

    case Finch.stream_while(request, Streamix.StreamFinch, acc, &on_chunk/2,
           receive_timeout: @receive_timeout,
           pool_timeout: 5_000
         ) do
      {:ok, %{outcome: nil, status: status}} when status in [200, 206] ->
        {:ok, status}

      {:ok, %{outcome: outcome}} ->
        outcome

      {:error, reason, acc} ->
        resume_or_fail(job, final_url, acc, resumes_left, reason)
    end
  end

  # A drop before the upstream said anything useful is retried like any
  # other; one after some bytes arrived asks only for what is still missing.
  # A failure that is not a transport error (a bad status, a refused range)
  # is final.
  defp resume_or_fail(job, final_url, %{outcome: nil} = acc, resumes_left, reason)
       when resumes_left > 0 and acc.offset <= job.range_end do
    if transport_error?(reason) do
      Logger.info(
        "[VodMux] upstream dropped the block at byte #{acc.offset}; resuming (#{resumes_left} left)"
      )

      progress = Map.take(acc, [:fetcher, :offset, :head_sent?, :status])
      fetch_range(job, final_url, progress, resumes_left - 1)
    else
      fail(reason)
    end
  end

  defp resume_or_fail(_job, _final_url, %{outcome: nil}, _resumes_left, reason), do: fail(reason)
  defp resume_or_fail(_job, _final_url, %{outcome: outcome}, _resumes_left, _reason), do: outcome

  defp fail(reason) do
    Logger.warning("[VodMux] block fetch failed: #{SafeLog.redact_inspect(reason)}")
    {:error, reason}
  end

  defp transport_error?(%Mint.TransportError{}), do: true
  defp transport_error?(%Finch.TransportError{}), do: true
  defp transport_error?(%Mint.HTTPError{reason: {:server_closed_connection, _, _}}), do: true
  defp transport_error?(_reason), do: false

  defp on_chunk({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp on_chunk({:headers, headers}, %{status: status} = acc) when status in [200, 206] do
    accept(acc, headers)
  end

  # Past end of file — a legitimate answer for the last block.
  defp on_chunk({:headers, _headers}, %{status: 416} = acc) do
    total_size = BlockStore.total_size(elem(acc.job.key, 0))
    acc = send_head(acc, total_size)
    {:halt, %{acc | outcome: {:ok, 416}}}
  end

  defp on_chunk({:headers, _headers}, %{status: status} = acc) do
    {:halt, %{acc | outcome: {:error, {:unexpected_status, status}}}}
  end

  defp on_chunk({:data, data}, acc) do
    # Never more than the block holds: an upstream that ignored the Range
    # would otherwise send the rest of the movie.
    wanted = acc.job.range_end - acc.offset + 1
    data = binary_part(data, 0, min(byte_size(data), max(wanted, 0)))

    if data != "", do: send(acc.fetcher, {:block_data, data})

    acc = %{acc | offset: acc.offset + byte_size(data)}

    if acc.offset > acc.job.range_end, do: {:halt, acc}, else: {:cont, acc}
  end

  defp on_chunk(_other, acc), do: {:cont, acc}

  # `Content-Range: bytes 0-4194303/1234567890` is the only place the upstream
  # tells us how long the movie is. A plain 200 means it ignored the Range and
  # is sending the whole resource from byte zero, which is only usable when
  # that is where this block — or this resume — starts.
  defp accept(%{status: 206} = acc, headers) do
    case content_range(headers) do
      {:ok, range_start, total_size} when range_start == acc.offset ->
        {:cont, send_head(acc, total_size)}

      {:ok, _other_start, _total_size} ->
        {:halt, %{acc | outcome: {:error, :range_mismatch}}}

      :error ->
        {:cont, send_head(acc, nil)}
    end
  end

  defp accept(%{status: 200, offset: 0} = acc, headers) do
    {:cont, send_head(acc, content_length(headers))}
  end

  defp accept(%{status: 200} = acc, _headers) do
    {:halt, %{acc | outcome: {:error, :range_ignored}}}
  end

  defp send_head(%{head_sent?: true} = acc, _total_size), do: acc

  defp send_head(acc, total_size) do
    send(acc.fetcher, {:block_head, total_size})
    %{acc | head_sent?: true}
  end

  defp content_range(headers) do
    with {_name, value} <- List.keyfind(headers, "content-range", 0),
         ["bytes " <> span, total] <- String.split(value, "/", parts: 2),
         [first, _last] <- String.split(span, "-", parts: 2),
         {range_start, ""} <- Integer.parse(String.trim(first)),
         {total_size, ""} <- Integer.parse(String.trim(total)) do
      {:ok, range_start, total_size}
    else
      _ -> :error
    end
  end

  defp content_length(headers) do
    with {_name, value} <- List.keyfind(headers, "content-length", 0),
         {length, ""} <- Integer.parse(String.trim(value)),
         true <- length > 0 do
      length
    else
      _ -> nil
    end
  end

  defp maybe_store_total_size(_state, nil), do: :ok

  defp maybe_store_total_size(state, total_size) do
    BlockStore.put_total_size(elem(state.key, 0), total_size)
  end

  # Only a complete block is cached: a short one (the last block of the file
  # is the exception, and it ends exactly at the resource length) would make
  # every later reader see a truncated movie.
  defp store(state, status, body) when status in [200, 206] and body != "" do
    expected = state.range_end - state.range_start + 1

    last_block? =
      is_integer(state.total_size) and state.range_start + byte_size(body) == state.total_size

    if byte_size(body) == expected or last_block? do
      BlockStore.put(state.key, body)
    else
      :ok
    end
  end

  defp store(_state, _status, _body), do: :ok
end
