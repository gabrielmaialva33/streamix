defmodule Streamix.Embedplay.Sessions do
  @moduledoc false
  use GenServer

  alias Streamix.Embedplay
  alias Streamix.Embedplay.HTTP

  # A session outlives its cache entry on purpose: `session_ttl_seconds` only
  # stops *new* playbacks from reusing a resolution, while a viewer already
  # streaming keeps touching the session and must not lose its resource graph
  # mid-playlist. `idle_seconds` is therefore the real eviction clock and has
  # to stay >= `session_ttl_seconds`, or an active stream loses its segments
  # the moment the resolution stops being cacheable.
  @default_idle_seconds 1800
  @max_resources 20_000
  @max_registry_bytes 4 * 1024 * 1024
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
         resource when not is_nil(resource) <- session.resources[rid] do
      {:reply, {:ok, Map.merge(resource, %{headers: session.headers})}, touch(state, sid)}
    else
      true -> {:reply, {:error, :playback_restart_required}, remove(state, sid)}
      _ -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call({:register, sid, movie_id, urls}, _from, state) do
    case state.sessions[sid] do
      %{movie_id: ^movie_id} = session ->
        new_urls = Enum.reject(urls, &Map.has_key?(session.urls, &1))
        added_bytes = Enum.sum(Enum.map(new_urls, fn {url, _kind} -> byte_size(url) end))

        if map_size(session.resources) + length(new_urls) > @max_resources or
             session.registry_bytes + added_bytes > @max_registry_bytes do
          {:reply, {:error, :resource_limit}, state}
        else
          {ids, session} = register_urls(urls, session)
          session = %{session | registry_bytes: session.registry_bytes + added_bytes}
          {:reply, {:ok, ids}, put_in(state.sessions[sid], session)}
        end

      _ ->
        {:reply, {:error, :resource_not_found}, state}
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
    root = opaque_id() <> ".m3u8"

    session = %{
      id: sid,
      root: root,
      movie_id: movie_id,
      headers: source.headers,
      created_at: now(),
      touched_at: now(),
      expires_at: parse_expiry(source.expires_at),
      registry_bytes: byte_size(source.url),
      resources: %{root => %{url: source.url, kind: :playlist}},
      urls: %{{source.url, :playlist} => root}
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

  defp register_urls(urls, session) do
    Enum.map_reduce(urls, session, &register_url/2)
  end

  defp register_url({url, kind} = key, session) do
    case session.urls[key] do
      nil ->
        rid = opaque_id() <> if(kind == :playlist, do: ".m3u8", else: ".bin")

        session = %{
          session
          | resources: Map.put(session.resources, rid, %{url: url, kind: kind}),
            urls: Map.put(session.urls, key, rid)
        }

        {rid, session}

      rid ->
        {rid, session}
    end
  end

  defp cached(state, movie_id) do
    with sid when not is_nil(sid) <- state.cache[movie_id],
         session when not is_nil(session) <- state.sessions[sid],
         true <- now() - session.created_at < session_ttl_seconds(),
         false <- expired?(session) do
      session
    else
      _ -> nil
    end
  end

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
  defp public(session), do: %{session_id: session.id, resource_id: session.root}
  defp now, do: System.monotonic_time(:second)
  defp max_sessions, do: Embedplay.config(:max_sessions, 128)

  # Every playlist, key and segment fetch takes a lease, so this bounds
  # concurrent upstream requests — not concurrent viewers. Sized against
  # `max_sessions` rather than a fixed number, because a cap that is small
  # relative to the session pool surfaces as `provider_capacity_exhausted`
  # mid-stream, which a player reports as a stall rather than a retry.
  defp max_concurrent_fetches,
    do: Embedplay.config(:max_concurrent_fetches, 64)

  defp idle_seconds,
    do: max(Embedplay.config(:idle_seconds, @default_idle_seconds), session_ttl_seconds())

  defp session_ttl_seconds, do: Embedplay.config(:session_ttl_seconds, 600)
  defp opaque_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 60_000)

  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_unix(time)
      _ -> nil
    end
  end

  defp parse_expiry(_), do: nil
end
