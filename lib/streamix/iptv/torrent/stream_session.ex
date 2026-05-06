defmodule Streamix.Iptv.Torrent.StreamSession do
  @moduledoc """
  GenServer that owns the lifecycle of a single rqbit torrent while
  Streamix users are watching it.

  One process per `info_hash`, registered in
  `Streamix.Iptv.Torrent.StreamRegistry`. The first viewer triggers an
  `add` call on rqbit; subsequent viewers piggy-back on the same
  process. When the last viewer leaves we schedule a 60s grace period
  before exiting — the `Reaper` (or our own `terminate/2`) tells rqbit
  to drop the torrent so disk doesn't fill up.

  Viewer pids are monitored: a crashed LiveView automatically
  decrements the viewer count without the controller needing to clean
  up explicitly.

  ## Public API

  * `start_or_join/3` — first call boots the session, subsequent calls
    just register the viewer. Blocks until rqbit reports `state ==
    "live"` and at least `@ready_bytes` are buffered, or returns
    `{:error, :timeout}` after `@ready_timeout_ms`.
  * `touch/2`   — heartbeat from the controller.
  * `leave/2`   — viewer disconnect.
  * `whereis/1` — registry lookup (test helper).
  """

  use GenServer

  require Logger

  alias Streamix.Iptv.Torrent.Client

  @registry Streamix.Iptv.Torrent.StreamRegistry
  @supervisor Streamix.Iptv.Torrent.StreamSessionSupervisor

  # Bytes that must be buffered before we let the controller hand off
  # to the player. 5 MB picks up the moov atom for most mp4/mkv files
  # and gives the player ~5–10 s of seek headroom.
  @ready_bytes 5_000_000

  # How often we poll rqbit while waiting for `state == "live"`.
  @ready_poll_ms 250

  # Hard ceiling on the wait — controller surfaces 504 to the client
  # and the player retries. 30 s matches `start_or_join/3`'s caller
  # timeout in the controller.
  @ready_timeout_ms 30_000

  # Idle grace before we exit when the last viewer leaves. Gives a
  # navigating user time to come back without re-triggering the rqbit
  # add + buffer cycle.
  @idle_grace_ms 60_000

  # Heuristic — extension list for "this is the video file".
  @video_exts ~w(.mp4 .mkv .mov .avi .ts .webm .m4v .flv .wmv)

  # ---- Public API ----

  @type info_hash :: String.t()

  def start_link(opts) do
    info_hash = Keyword.fetch!(opts, :info_hash) |> normalize_hash()

    GenServer.start_link(__MODULE__, Keyword.put(opts, :info_hash, info_hash),
      name: via(info_hash)
    )
  end

  @doc """
  Boots a session for `info_hash` (or joins an existing one) and
  blocks until rqbit reports it ready. Registers `viewer_pid` as a
  viewer. Returns `{:ok, %{info_hash, file_idx}}` on success.
  """
  @spec start_or_join(info_hash(), String.t(), pid()) ::
          {:ok, %{info_hash: info_hash(), file_idx: non_neg_integer()}}
          | {:error, term()}
  def start_or_join(info_hash, magnet_uri, viewer_pid)
      when is_binary(info_hash) and is_binary(magnet_uri) and is_pid(viewer_pid) do
    info_hash = normalize_hash(info_hash)

    pid =
      case whereis(info_hash) do
        nil ->
          spec = {__MODULE__, [info_hash: info_hash, magnet_uri: magnet_uri]}

          case DynamicSupervisor.start_child(@supervisor, spec) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
            {:error, reason} -> throw({:start_error, reason})
          end

        pid ->
          pid
      end

    GenServer.call(pid, {:join_and_wait, viewer_pid}, @ready_timeout_ms + 5_000)
  catch
    {:start_error, reason} -> {:error, reason}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :session_not_started}
  end

  @doc """
  Heartbeat from the controller. Refreshes the viewer's last-touch
  timestamp.
  """
  @spec touch(info_hash(), pid()) :: :ok
  def touch(info_hash, viewer_pid) do
    case whereis(normalize_hash(info_hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:touch, viewer_pid})
    end
  end

  @doc """
  Notifies the session that `viewer_pid` has disconnected. If it was
  the last viewer, schedules a teardown after the idle grace.
  """
  @spec leave(info_hash(), pid()) :: :ok
  def leave(info_hash, viewer_pid) do
    case whereis(normalize_hash(info_hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:leave, viewer_pid})
    end
  end

  @doc """
  Returns the pid of the session for `info_hash`, or nil.
  """
  @spec whereis(info_hash()) :: pid() | nil
  def whereis(info_hash) do
    case Registry.lookup(@registry, normalize_hash(info_hash)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(info_hash), do: {:via, Registry, {@registry, info_hash}}

  defp normalize_hash(hash) when is_binary(hash), do: String.downcase(hash)

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    info_hash = Keyword.fetch!(opts, :info_hash)
    magnet_uri = Keyword.fetch!(opts, :magnet_uri)

    state = %{
      info_hash: info_hash,
      magnet_uri: magnet_uri,
      file_idx: nil,
      ready?: false,
      added?: false,
      viewers: %{},
      monitors: %{},
      idle_timer: nil,
      pending_joins: []
    }

    {:ok, state, {:continue, :ensure_added}}
  end

  @impl true
  def handle_continue(:ensure_added, state) do
    case Client.add(state.magnet_uri) do
      {:ok, summary} ->
        file_idx = pick_video_file(summary)

        Logger.info(
          "[Torrent.StreamSession] added #{state.info_hash}, file_idx=#{inspect(file_idx)}"
        )

        schedule_ready_check()
        {:noreply, %{state | added?: true, file_idx: file_idx}}

      {:error, reason} ->
        Logger.warning(
          "[Torrent.StreamSession] add failed for #{state.info_hash}: #{inspect(reason)}"
        )

        # Tell pending joiners and bow out — the session can't recover
        # without a working rqbit add.
        {:stop, {:add_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:join_and_wait, viewer_pid}, from, state) do
    state = register_viewer(state, viewer_pid)

    cond do
      state.ready? and is_integer(state.file_idx) ->
        {:reply, {:ok, %{info_hash: state.info_hash, file_idx: state.file_idx}}, state}

      true ->
        # Defer the reply until ready_check confirms `state == "live"`
        # and progress >= @ready_bytes.
        deadline = System.monotonic_time(:millisecond) + @ready_timeout_ms
        {:noreply, %{state | pending_joins: [{from, deadline} | state.pending_joins]}}
    end
  end

  @impl true
  def handle_cast({:touch, viewer_pid}, state) do
    {:noreply, touch_viewer(state, viewer_pid)}
  end

  @impl true
  def handle_cast({:leave, viewer_pid}, state) do
    {:noreply, drop_viewer(state, viewer_pid)}
  end

  @impl true
  def handle_info(:ready_check, state) do
    case Client.stats(state.info_hash) do
      {:ok, stats} ->
        cond do
          state.ready? ->
            {:noreply, state}

          live_and_buffered?(stats) ->
            file_idx = state.file_idx || try_pick_file_now(state.info_hash)
            state = %{state | ready?: true, file_idx: file_idx}

            state =
              reply_pending_joins(state, {:ok, %{info_hash: state.info_hash, file_idx: file_idx}})

            {:noreply, state}

          true ->
            schedule_ready_check()
            {:noreply, prune_expired_joins(state)}
        end

      {:error, _reason} ->
        schedule_ready_check()
        {:noreply, prune_expired_joins(state)}
    end
  end

  @impl true
  def handle_info(:check_idle, state) do
    state = %{state | idle_timer: nil}

    if map_size(state.viewers) == 0 do
      Logger.info("[Torrent.StreamSession] idle grace expired for #{state.info_hash}, exiting")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {^pid, monitors} ->
        viewers = Map.delete(state.viewers, pid)
        state = %{state | viewers: viewers, monitors: monitors}
        {:noreply, maybe_schedule_idle(state)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Reply to anyone still waiting so they don't hang on the timeout.
    Enum.each(state.pending_joins, fn {from, _deadline} ->
      try do
        GenServer.reply(from, {:error, :session_terminated})
      rescue
        _ -> :ok
      end
    end)

    if state.added? do
      _ = Client.remove(state.info_hash)
    end

    :ok
  end

  # ---- Helpers ----

  defp register_viewer(state, viewer_pid) do
    case Map.get(state.viewers, viewer_pid) do
      nil ->
        ref = Process.monitor(viewer_pid)

        state = cancel_idle(state)

        %{
          state
          | viewers: Map.put(state.viewers, viewer_pid, now_ms()),
            monitors: Map.put(state.monitors, ref, viewer_pid)
        }

      _last_touch ->
        touch_viewer(state, viewer_pid)
    end
  end

  defp touch_viewer(state, viewer_pid) do
    if Map.has_key?(state.viewers, viewer_pid) do
      %{state | viewers: Map.put(state.viewers, viewer_pid, now_ms())}
    else
      register_viewer(state, viewer_pid)
    end
  end

  defp drop_viewer(state, viewer_pid) do
    case Map.pop(state.viewers, viewer_pid) do
      {nil, _} ->
        state

      {_, viewers} ->
        # Demonitor too — find the ref bound to this pid.
        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, state.monitors}, fn
            {r, ^viewer_pid}, {nil, acc} -> {r, Map.delete(acc, r)}
            _, acc -> acc
          end)

        if ref, do: Process.demonitor(ref, [:flush])

        state = %{state | viewers: viewers, monitors: monitors}
        maybe_schedule_idle(state)
    end
  end

  defp maybe_schedule_idle(%{viewers: viewers} = state) when map_size(viewers) == 0 do
    cancel_idle(state)
    timer = Process.send_after(self(), :check_idle, @idle_grace_ms)
    %{state | idle_timer: timer}
  end

  defp maybe_schedule_idle(state), do: state

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp schedule_ready_check do
    Process.send_after(self(), :ready_check, @ready_poll_ms)
  end

  defp live_and_buffered?(%{state: "live", progress_bytes: bytes}) when bytes >= @ready_bytes,
    do: true

  defp live_and_buffered?(%{finished: true}), do: true
  defp live_and_buffered?(_), do: false

  defp pick_video_file(%{files: files}) when is_list(files) and files != [] do
    files
    |> Enum.with_index()
    |> Enum.filter(fn {file, _idx} -> video_file?(file) end)
    |> Enum.max_by(fn {file, _idx} -> Map.get(file, :length, 0) end, fn -> nil end)
    |> case do
      nil -> 0
      {_file, idx} -> idx
    end
  end

  defp pick_video_file(_), do: 0

  defp video_file?(%{name: name}) when is_binary(name) do
    ext = name |> Path.extname() |> String.downcase()
    ext in @video_exts
  end

  defp video_file?(_), do: false

  defp try_pick_file_now(info_hash) do
    case Client.details(info_hash) do
      {:ok, summary} -> pick_video_file(summary)
      _ -> 0
    end
  end

  defp reply_pending_joins(state, reply) do
    Enum.each(state.pending_joins, fn {from, _deadline} ->
      GenServer.reply(from, reply)
    end)

    %{state | pending_joins: []}
  end

  defp prune_expired_joins(state) do
    now = System.monotonic_time(:millisecond)

    {expired, alive} =
      Enum.split_with(state.pending_joins, fn {_from, deadline} -> deadline <= now end)

    Enum.each(expired, fn {from, _} -> GenServer.reply(from, {:error, :timeout}) end)

    %{state | pending_joins: alive}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
