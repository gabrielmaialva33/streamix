defmodule Streamix.Embedplay.Sessions do
  @moduledoc false
  use GenServer

  alias Streamix.Embedplay
  alias Streamix.Embedplay.HTTP
  alias Streamix.Hls.Registry

  # A session outlives its cache entry on purpose: `session_ttl_seconds` only
  # stops *new* playbacks from reusing a resolution, while a viewer already
  # streaming keeps touching the session and must not lose its resource graph
  # mid-playlist. `idle_seconds` is therefore the real eviction clock and has
  # to stay >= `session_ttl_seconds`, or an active stream loses its segments
  # the moment the resolution stops being cacheable. Each session's resource
  # graph (and its size limits) is a shared `Streamix.Hls.Registry`.
  @default_idle_seconds 1800
  @max_waiters 64

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def open(movie) do
    GenServer.call(
      __MODULE__,
      {:open, movie},
      Embedplay.config(:resolve_timeout_ms, 45_000) + 5000
    )
  end

  def resource(session_id, resource_id, movie_id),
    do: GenServer.call(__MODULE__, {:resource, session_id, resource_id, movie_id})

  def register(session_id, movie_id, urls),
    do: GenServer.call(__MODULE__, {:register, session_id, movie_id, urls})

  def invalidate(session_id), do: GenServer.call(__MODULE__, {:invalidate, session_id})

  # A progressive transfer is one request that can outlast `idle_seconds`, so
  # the gateway reports activity while bytes still flow.
  def touch(session_id), do: GenServer.cast(__MODULE__, {:touch, session_id})
  def acquire, do: GenServer.call(__MODULE__, :acquire)
  def release(ref), do: GenServer.call(__MODULE__, {:release, ref})

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{sessions: %{}, cache: %{}, pending: %{}, tasks: %{}, leases: %{}}}
  end

  @impl true
  def handle_call({:open, movie}, from, state) do
    state = cleanup(state)

    cond do
      not Embedplay.enabled?() ->
        {:reply, {:error, :provider_disabled}, state}

      session = cached(state, movie.id) ->
        {:reply, {:ok, public(session)}, touch(state, session.id)}

      pending = state.pending[movie.id] ->
        queue_waiter(state, pending, movie.id, from)

      map_size(state.sessions) + map_size(state.pending) >= max_sessions() ->
        {:reply, {:error, :provider_capacity_exhausted}, state}

      true ->
        task =
          Task.Supervisor.async_nolink(Streamix.TaskSupervisor, fn -> HTTP.resolve(movie) end)

        timer =
          Process.send_after(
            self(),
            {:resolve_timeout, task.ref},
            Embedplay.config(:resolve_timeout_ms, 45_000)
          )

        pending = %{waiters: [from], task: task, timer: timer}

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, movie.id, pending),
             tasks: Map.put(state.tasks, task.ref, movie.id)
         }}
    end
  end

  def handle_call({:resource, sid, rid, movie_id}, _from, state) do
    with %{movie_id: ^movie_id} = session <- state.sessions[sid],
         false <- expired?(session),
         {:ok, resource} <- Registry.lookup(session.registry, rid) do
      {:reply, {:ok, Map.merge(resource, %{headers: session.headers})}, touch(state, sid)}
    else
      true -> {:reply, {:error, :playback_restart_required}, remove(state, sid)}
      _ -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call({:register, sid, movie_id, urls}, _from, state) do
    with %{movie_id: ^movie_id} = session <- state.sessions[sid],
         {:ok, ids, registry} <- Registry.register(session.registry, urls) do
      {:reply, {:ok, ids}, put_in(state.sessions[sid].registry, registry)}
    else
      {:error, :resource_limit} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call({:invalidate, sid}, _from, state), do: {:reply, :ok, remove(state, sid)}

  def handle_call(:acquire, {pid, _}, state) do
    if map_size(state.leases) < max_concurrent_fetches() do
      ref = Process.monitor(pid)
      {:reply, {:ok, ref}, put_in(state.leases[ref], pid)}
    else
      {:reply, {:error, :provider_capacity_exhausted}, state}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | leases: Map.delete(state.leases, ref)}}
  end

  @impl true
  def handle_cast({:touch, sid}, state) do
    if Map.has_key?(state.sessions, sid),
      do: {:noreply, touch(state, sid)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{state | leases: Map.delete(state.leases, ref)}
    {:noreply, finish(state, ref, {:error, :stream_resolution_failed})}
  end

  def handle_info({:resolve_timeout, ref}, state) do
    if movie_id = state.tasks[ref] do
      Task.shutdown(state.pending[movie_id].task, :brutal_kill)
    end

    {:noreply, finish(state, ref, {:error, :upstream_timeout})}
  end

  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, cleanup(state)}
  end

  defp queue_waiter(state, pending, movie_id, from) do
    if length(pending.waiters) < @max_waiters do
      {:noreply, put_in(state.pending[movie_id].waiters, [from | pending.waiters])}
    else
      {:reply, {:error, :provider_capacity_exhausted}, state}
    end
  end

  defp finish(state, ref, result) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        state

      {movie_id, tasks} ->
        {pending, pending_map} = Map.pop(state.pending, movie_id)
        Process.cancel_timer(pending.timer)
        state = %{state | tasks: tasks, pending: pending_map}
        {reply, state} = finish_result(result, movie_id, state)
        Enum.each(pending.waiters, &GenServer.reply(&1, reply))
        state
    end
  end

  defp finish_result({:ok, source}, movie_id, state) do
    sid = opaque_id()
    kind = Map.get(source, :kind, :hls)

    session = %{
      id: sid,
      kind: kind,
      movie_id: movie_id,
      headers: source.headers,
      created_at: now(),
      touched_at: now(),
      expires_at: parse_expiry(source.expires_at),
      registry: Registry.new(source.url, root_kind(kind))
    }

    state = %{
      state
      | sessions: Map.put(state.sessions, sid, session),
        cache: Map.put(state.cache, movie_id, sid)
    }

    {{:ok, public(session)}, state}
  end

  defp finish_result({:error, reason}, _movie_id, state), do: {{:error, reason}, state}
  defp finish_result(_, _movie_id, state), do: {{:error, :stream_resolution_failed}, state}

  # An HLS root is a playlist whose rewrite registers the rest of the graph.
  # A progressive MP4 root is the whole movie: one media resource the gateway
  # streams through, and nothing else is ever registered for it. The registry
  # names them `.mp4` and `.m3u8`, and other HLS media `.bin`.
  defp root_kind(:mp4), do: :progressive
  defp root_kind(_hls), do: :playlist

  defp cached(state, movie_id) do
    with sid when not is_nil(sid) <- state.cache[movie_id],
         session when not is_nil(session) <- state.sessions[sid],
         true <- reusable?(session),
         false <- expired?(session) do
      session
    else
      _ -> nil
    end
  end

  # An HLS viewer opens the movie once and then only touches resource URLs
  # carrying its session id, so `session_ttl_seconds` can safely send *new*
  # starts to a fresh resolution. A progressive movie has one stable URL and
  # every range request — each seek, each reconnect — opens the movie again.
  # Applying the TTL there would re-resolve mid-movie (a ~10 s browser run
  # per request) and could hand later ranges of the same playback a different
  # file. So an MP4 session is reused for as long as it is alive: until it
  # goes idle, reaches an explicit resolver expiry, or upstream stops
  # authorizing it (which invalidates it, and the next request resolves again).
  defp reusable?(%{kind: :mp4}), do: true
  defp reusable?(session), do: now() - session.created_at < session_ttl_seconds()

  defp cleanup(state) do
    Enum.reduce(state.sessions, state, fn {sid, session}, acc ->
      if expired?(session), do: remove(acc, sid), else: acc
    end)
  end

  defp expired?(session) do
    now() - session.touched_at >= idle_seconds() or
      (session.expires_at != nil and System.system_time(:second) >= session.expires_at)
  end

  defp remove(state, sid) do
    %{
      state
      | sessions: Map.delete(state.sessions, sid),
        cache: Map.reject(state.cache, fn {_movie_id, cached_sid} -> cached_sid == sid end)
    }
  end

  defp touch(state, sid), do: put_in(state.sessions[sid].touched_at, now())

  defp public(session),
    do: %{
      session_id: session.id,
      resource_id: Registry.root(session.registry),
      kind: session.kind
    }

  defp now, do: System.monotonic_time(:second)
  defp max_sessions, do: Embedplay.config(:max_sessions, 128)

  # Every playlist, key and segment fetch takes a lease, so this bounds
  # concurrent upstream requests — not concurrent viewers. Sized against
  # `max_sessions` rather than a fixed number, because a cap that is small
  # relative to the session pool surfaces as `provider_capacity_exhausted`
  # mid-stream, which a player reports as a stall rather than a retry.
  #
  # A progressive MP4 transfer is different: it keeps its lease for as long as
  # the player keeps that one response open, often the whole movie, plus a
  # brief overlap while a seek replaces it. For MP4 sources this cap is
  # therefore roughly the number of concurrent viewers, and a viewer seeking
  # while it is exhausted gets a 503 for that range.
  defp max_concurrent_fetches,
    do: Embedplay.config(:max_concurrent_fetches, 64)

  defp idle_seconds,
    do: max(Embedplay.config(:idle_seconds, @default_idle_seconds), session_ttl_seconds())

  defp session_ttl_seconds, do: Embedplay.config(:session_ttl_seconds, 600)
  defp opaque_id, do: Registry.opaque_id()
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 60_000)

  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_unix(time)
      _ -> nil
    end
  end

  defp parse_expiry(_), do: nil
end
