defmodule Streamix.Iptv.Streaming.XtreamHls.Sessions do
  @moduledoc """
  Sessions and per-provider fetch leases for Xtream HLS playback.

  A session ties one content item (`{:movie, id}` or `{:episode, id}`) to a
  `Streamix.Hls.Registry` whose root is the item's Xtream URL. That URL embeds
  the account credentials, so it lives only in this process: clients see the
  opaque session and resource identifiers.

  Opening an item reuses its session for `session_ttl_seconds` (default 600)
  while the source URL is unchanged — a provider whose credentials changed
  gets a fresh session at once. A session stays alive while it is used and is
  removed after `idle_seconds` (default 1800) without a request, or as soon as
  an upstream answers 401/403/410 for one of its resources.

  ## Leases

  Every upstream fetch (playlist, key, segment) holds a lease for its
  duration. At most `max_fetches_per_provider` (default 16) run at once per
  provider. A request beyond that waits in a bounded FIFO for up to
  `lease_wait_ms` (default 5 s) instead of failing at once, because an HLS
  player fetches audio and video segments in parallel and a momentary burst
  should queue, not surface as an error. Leases are tied to the requesting
  process and reclaimed if it dies.

  Configuration lives under `config :streamix, :xtream_hls`. State is
  node-local, like `Streamix.Embedplay.Sessions`: a multi-node deployment needs
  sticky routing before this path is used there.
  """

  use GenServer

  alias Streamix.Hls.Registry

  @max_waiters 256
  @cleanup_interval_ms 60_000

  @type content :: {:movie | :episode, pos_integer()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Opens (or reuses) the session for `content` whose root playlist is `url`."
  @spec open(content(), integer(), String.t()) ::
          {:ok, %{session_id: String.t(), resource_id: String.t()}} | {:error, atom()}
  def open(content, provider_id, url),
    do: GenServer.call(__MODULE__, {:open, content, provider_id, url})

  @doc "Looks up a resource of a session opened for `content`."
  def resource(session_id, resource_id, content),
    do: GenServer.call(__MODULE__, {:resource, session_id, resource_id, content})

  @doc "Registers playlist references on a session; returns one identifier per reference."
  def register(session_id, content, refs),
    do: GenServer.call(__MODULE__, {:register, session_id, content, refs})

  @doc "Drops a session and its resource graph."
  def invalidate(session_id), do: GenServer.call(__MODULE__, {:invalidate, session_id})

  @doc "Takes one upstream fetch slot for `provider_id`, waiting up to `lease_wait_ms`."
  @spec acquire(integer()) :: {:ok, reference()} | {:error, :provider_capacity_exhausted}
  def acquire(provider_id),
    do: GenServer.call(__MODULE__, {:acquire, provider_id}, lease_wait_ms() + 5_000)

  @doc "Returns a fetch slot."
  def release(ref), do: GenServer.call(__MODULE__, {:release, ref})

  @doc "Configuration value under `:xtream_hls`."
  def config(key, default),
    do: Keyword.get(Application.get_env(:streamix, :xtream_hls, []), key) || default

  @impl true
  def init(_opts) do
    schedule_cleanup()

    {:ok, %{sessions: %{}, cache: %{}, leases: %{}, counts: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:open, content, provider_id, url}, _from, state) do
    state = cleanup(state)

    cond do
      session = cached(state, content, url) ->
        {:reply, {:ok, public(session)}, touch(state, session.id)}

      map_size(state.sessions) >= max_sessions() ->
        {:reply, {:error, :provider_capacity_exhausted}, state}

      true ->
        session = new_session(content, provider_id, url)

        state = %{
          state
          | sessions: Map.put(state.sessions, session.id, session),
            cache: Map.put(state.cache, content, session.id)
        }

        {:reply, {:ok, public(session)}, state}
    end
  end

  def handle_call({:resource, sid, rid, content}, _from, state) do
    with %{content: ^content} = session <- state.sessions[sid],
         false <- expired?(session),
         {:ok, resource} <- Registry.lookup(session.registry, rid) do
      {:reply, {:ok, resource, session.provider_id}, touch(state, sid)}
    else
      true -> {:reply, {:error, :playback_restart_required}, remove(state, sid)}
      _ -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call({:register, sid, content, refs}, _from, state) do
    with %{content: ^content} = session <- state.sessions[sid],
         {:ok, ids, registry} <- Registry.register(session.registry, refs) do
      {:reply, {:ok, ids}, put_in(state.sessions[sid].registry, registry)}
    else
      {:error, :resource_limit} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call({:invalidate, sid}, _from, state), do: {:reply, :ok, remove(state, sid)}

  def handle_call({:acquire, provider_id}, {pid, _tag} = from, state) do
    queue = Map.get(state.waiters, provider_id, :queue.new())

    cond do
      Map.get(state.counts, provider_id, 0) < max_fetches() ->
        {ref, state} = grant(state, provider_id, pid)
        {:reply, {:ok, ref}, state}

      :queue.len(queue) >= @max_waiters ->
        {:reply, {:error, :provider_capacity_exhausted}, state}

      true ->
        tag = make_ref()
        Process.send_after(self(), {:lease_timeout, provider_id, tag}, lease_wait_ms())
        queue = :queue.in({tag, from}, queue)
        {:noreply, put_in(state.waiters[provider_id], queue)}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, drop_lease(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, drop_lease(state, ref)}

  def handle_info({:lease_timeout, provider_id, tag}, state) do
    queue = Map.get(state.waiters, provider_id, :queue.new())

    {expired, rest} =
      :queue.to_list(queue) |> Enum.split_with(fn {waiter, _from} -> waiter == tag end)

    Enum.each(expired, fn {_tag, from} ->
      GenServer.reply(from, {:error, :provider_capacity_exhausted})
    end)

    {:noreply, put_waiters(state, provider_id, :queue.from_list(rest))}
  end

  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, cleanup(state)}
  end

  defp grant(state, provider_id, pid) do
    ref = Process.monitor(pid)

    state = %{
      state
      | leases: Map.put(state.leases, ref, provider_id),
        counts: Map.update(state.counts, provider_id, 1, &(&1 + 1))
    }

    {ref, state}
  end

  # A released slot goes straight to the oldest waiter of that provider.
  defp drop_lease(state, ref) do
    case Map.pop(state.leases, ref) do
      {nil, _leases} ->
        state

      {provider_id, leases} ->
        count = Map.get(state.counts, provider_id, 1) - 1

        counts =
          if count > 0,
            do: Map.put(state.counts, provider_id, count),
            else: Map.delete(state.counts, provider_id)

        serve_waiter(%{state | leases: leases, counts: counts}, provider_id)
    end
  end

  defp serve_waiter(state, provider_id) do
    queue = Map.get(state.waiters, provider_id, :queue.new())

    case :queue.out(queue) do
      {{:value, {_tag, {pid, _} = from}}, rest} ->
        {ref, state} = grant(put_waiters(state, provider_id, rest), provider_id, pid)
        GenServer.reply(from, {:ok, ref})
        state

      {:empty, _queue} ->
        state
    end
  end

  defp put_waiters(state, provider_id, queue) do
    if :queue.is_empty(queue),
      do: %{state | waiters: Map.delete(state.waiters, provider_id)},
      else: put_in(state.waiters[provider_id], queue)
  end

  defp new_session(content, provider_id, url) do
    %{
      id: Registry.opaque_id(),
      content: content,
      provider_id: provider_id,
      registry: Registry.new(url, :playlist, suffix: &suffix/2),
      created_at: now(),
      touched_at: now()
    }
  end

  defp cached(state, content, url) do
    with sid when not is_nil(sid) <- state.cache[content],
         session when not is_nil(session) <- state.sessions[sid],
         true <- Registry.root_url(session.registry) == url,
         true <- now() - session.created_at < session_ttl_seconds(),
         false <- expired?(session) do
      session
    else
      _ -> nil
    end
  end

  # Players that infer the container from the URL (some TV HLS stacks do) see
  # the upstream's own media extension when it is a known one. Anything else —
  # including CDNs that disguise segments as `.js` or `.png` — is `.bin`.
  @media_extensions ~w(ts aac m4s mp4 m4a m4v mp3 vtt webvtt key)

  defp suffix(:playlist, _url), do: ".m3u8"

  defp suffix(_kind, url) do
    extension =
      case URI.new(url) do
        {:ok, %URI{path: path}} when is_binary(path) ->
          path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

        _ ->
          ""
      end

    if extension in @media_extensions, do: "." <> extension, else: ".bin"
  end

  defp cleanup(state) do
    Enum.reduce(state.sessions, state, fn {sid, session}, acc ->
      if expired?(session), do: remove(acc, sid), else: acc
    end)
  end

  defp expired?(session), do: now() - session.touched_at >= idle_seconds()

  defp remove(state, sid) do
    %{
      state
      | sessions: Map.delete(state.sessions, sid),
        cache: Map.reject(state.cache, fn {_content, cached_sid} -> cached_sid == sid end)
    }
  end

  defp touch(state, sid), do: put_in(state.sessions[sid].touched_at, now())

  defp public(session),
    do: %{session_id: session.id, resource_id: Registry.root(session.registry)}

  defp now, do: System.monotonic_time(:second)
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp max_sessions, do: config(:max_sessions, 2_048)
  defp max_fetches, do: config(:max_fetches_per_provider, 16)
  defp lease_wait_ms, do: config(:lease_wait_ms, 5_000)
  defp session_ttl_seconds, do: config(:session_ttl_seconds, 600)

  defp idle_seconds,
    do: max(config(:idle_seconds, 1_800), session_ttl_seconds())
end
