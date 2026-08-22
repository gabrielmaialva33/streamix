defmodule Streamix.WatchParty.RoomServer do
  @moduledoc """
  One authoritative playback timeline for a Watch Party room.

  Room processes use distributed `:global` names, track browser connections
  separately from users, recover their last persisted playback snapshot after a
  restart, and terminate normally when the room is idle or the host does not
  return within the grace period.
  """
  use GenServer

  import Ecto.Query, warn: false

  alias Streamix.Repo
  alias Streamix.WatchParty.{Participant, Room}

  require Logger

  @sync_interval :timer.seconds(5)
  @idle_check_interval :timer.seconds(60)
  @idle_timeout :timer.minutes(5)
  @host_grace_timeout :timer.minutes(2)
  @snapshot_interval :timer.seconds(15)
  @command_lead_ms 350
  @max_drift_log 2.0
  @drift_resync_threshold 3.0
  @max_position_seconds 31_536_000
  @max_connection_id_bytes 128

  # --- Public API ---

  def child_spec(opts) do
    room_id = Keyword.fetch!(opts, :room_id)

    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  def join(room_id, user_id, connection_id) do
    GenServer.call(via(room_id), {:join, user_id, connection_id, self()})
  end

  def leave(room_id, user_id, connection_id) do
    GenServer.call(via(room_id), {:leave, user_id, connection_id, self()})
  end

  def playback_action(room_id, user_id, connection_id, action) do
    GenServer.call(via(room_id), {:playback_action, user_id, connection_id, self(), action})
  end

  def sync_beacon(
        room_id,
        user_id,
        connection_id,
        position,
        participant_state,
        buffering,
        client_time
      ) do
    GenServer.cast(
      via(room_id),
      {:sync_beacon, user_id, connection_id, self(), position, participant_state, buffering,
       client_time}
    )
  end

  def change_content(room_id, user_id, connection_id, content_ref) when is_map(content_ref) do
    GenServer.call(
      via(room_id),
      {:change_content, user_id, connection_id, self(), content_ref}
    )
  end

  def end_room(room_id, user_id, connection_id) do
    GenServer.call(via(room_id), {:end_room, user_id, connection_id, self()})
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :get_state)
  end

  def stop(room_id, reason \\ :normal) do
    case whereis(room_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, reason)
    end
  catch
    :exit, _reason -> :ok
  end

  def whereis(room_id) do
    case :global.whereis_name({__MODULE__, room_id}) do
      :undefined -> nil
      pid when is_pid(pid) -> pid
    end
  end

  defp via(room_id), do: {:global, {__MODULE__, room_id}}

  # --- Callbacks ---

  @impl true
  def init(opts) do
    persist? = Keyword.get(opts, :persist?, false)

    case load_snapshot(opts, persist?) do
      {:ok, snapshot} -> init_from_snapshot(snapshot, persist?)
      {:error, :room_inactive} -> {:stop, :normal}
    end
  end

  defp init_from_snapshot(snapshot, persist?) do
    monotonic_now = now()
    activity_updated_at = snapshot_activity_updated_at(snapshot)

    state = %{
      room_id: snapshot_room_id(snapshot),
      host_user_id: snapshot.host_user_id,
      catalog_item_id: snapshot.catalog_item_id,
      source_type: snapshot.source_type,
      source_id: snapshot.source_id,
      playback: restore_playback(snapshot),
      connections: %{},
      connection_monitors: %{},
      monitor_connections: %{},
      participant_states: %{},
      last_activity: restore_monotonic_activity(activity_updated_at, monotonic_now),
      activity_updated_at: activity_updated_at,
      last_persisted_at: monotonic_now,
      version: snapshot.playback_version,
      persist?: persist?,
      sync_timer: schedule_sync_broadcast(),
      idle_timer: schedule_idle_check(),
      host_grace_timer: nil,
      host_grace_ref: nil
    }

    Logger.info(
      "[WatchParty] Room #{state.room_id} started (host: #{state.host_user_id}, version: #{state.version})"
    )

    emit(:room_started, %{count: 1}, %{room_id: state.room_id})
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state[:sync_timer])
    cancel_timer(state[:idle_timer])
    cancel_timer(state[:host_grace_timer])
    :ok
  end

  @impl true
  def handle_call({:join, user_id, connection_id, owner_pid}, _from, state) do
    if valid_connection?(user_id, connection_id, owner_pid) do
      host_was_offline = user_id == state.host_user_id and not connected_user?(state, user_id)
      new_connection? = not connected_connection?(state, user_id, connection_id)

      state =
        state
        |> put_connection(user_id, connection_id, owner_pid)
        |> touch_activity()
        |> maybe_cancel_host_grace(user_id)
        |> maybe_schedule_host_grace()
        |> persist_snapshot(true)

      if host_was_offline do
        broadcast(state.room_id, {:host_status, :online})
      end

      if new_connection? do
        emit(:participant_joined, %{count: 1}, %{
          room_id: state.room_id,
          role: if(user_id == state.host_user_id, do: :host, else: :viewer)
        })
      end

      {:reply, {:ok, compute_current_playback(state.playback)}, state}
    else
      {:reply, {:error, :invalid_connection}, state}
    end
  end

  @impl true
  def handle_call({:leave, user_id, connection_id, _owner_pid}, _from, state) do
    state = state |> remove_connection(user_id, connection_id) |> touch_activity()
    {state, departure} = finish_connection_departure(state, user_id)
    state = persist_snapshot(state, true)

    if departure.room_empty? do
      Logger.info("[WatchParty] Room #{state.room_id} empty, waiting for idle timeout")
    end

    emit(:participant_left, %{count: 1}, %{room_id: state.room_id})
    {:reply, {:ok, departure}, state}
  end

  @impl true
  def handle_call(
        {:playback_action, user_id, connection_id, owner_pid, action},
        _from,
        state
      ) do
    state = recover_connection(state, user_id, connection_id, owner_pid)

    if host_connection?(state, user_id, connection_id) do
      handle_host_playback_action(state, action)
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  @impl true
  def handle_call(
        {:change_content, user_id, connection_id, owner_pid,
         %{catalog_item_id: catalog_item_id, source_type: source_type, source_id: source_id}},
        _from,
        state
      ) do
    state = recover_connection(state, user_id, connection_id, owner_pid)

    cond do
      not host_connection?(state, user_id, connection_id) ->
        {:reply, {:error, :not_host}, state}

      not valid_content_ref?(catalog_item_id, source_type, source_id) ->
        {:reply, {:error, :invalid_content_ref}, state}

      true ->
        state =
          state
          |> Map.put(:catalog_item_id, catalog_item_id)
          |> Map.put(:source_type, source_type)
          |> Map.put(:source_id, source_id)
          |> Map.put(:playback, paused_playback(0.0))
          |> touch_activity()
          |> bump_version()
          |> persist_snapshot(true)

        broadcast(state.room_id, {
          :content_changed,
          %{
            catalog_item_id: catalog_item_id,
            source_type: source_type,
            source_id: source_id,
            version: state.version
          }
        })

        emit(:content_changed, %{count: 1}, %{room_id: state.room_id})
        {:reply, {:ok, state.version}, state}
    end
  end

  @impl true
  def handle_call({:end_room, user_id, connection_id, owner_pid}, _from, state) do
    state = recover_connection(state, user_id, connection_id, owner_pid)

    if host_connection?(state, user_id, connection_id) do
      state = end_persisted_room(state, "host_ended")
      {:stop, :normal, :ok, state}
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    playback = compute_current_playback(state.playback)

    {:reply, {:ok, Map.put(playback, :version, state.version), state.host_user_id}, state}
  end

  @impl true
  def handle_cast(
        {:sync_beacon, user_id, connection_id, owner_pid, position, participant_state, buffering,
         _client_time},
        state
      ) do
    state = recover_connection(state, user_id, connection_id, owner_pid)

    if connected_connection?(state, user_id, connection_id) and
         valid_beacon?(position, participant_state, buffering) do
      participant_states =
        Map.put(state.participant_states, user_id, %{
          position: position,
          state: participant_state,
          buffering: buffering,
          last_seen: now()
        })

      state = %{state | participant_states: participant_states} |> touch_activity()

      state =
        if user_id == state.host_user_id do
          reconcile_host_beacon(state, position, participant_state, buffering)
        else
          maybe_resync_viewer(state, user_id, position, buffering)
        end

      {:noreply, persist_snapshot(state, false)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sync_broadcast, state) do
    state = %{state | sync_timer: schedule_sync_broadcast()}

    state =
      if participant_count(state) > 1 and broadcast_needed?(state) do
        broadcast_periodic_sync(state)
      else
        state
      end

    {:noreply, persist_snapshot(state, false)}
  end

  @impl true
  def handle_info(:idle_check, state) do
    state = %{state | idle_timer: schedule_idle_check()}
    idle_ms = now() - state.last_activity

    if connection_count(state) == 0 and idle_ms > @idle_timeout do
      Logger.info("[WatchParty] Room #{state.room_id} idle timeout, ending room")
      state = end_persisted_room(state, "idle_timeout")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:host_grace_expired, ref}, %{host_grace_ref: ref} = state) do
    if connected_user?(state, state.host_user_id) do
      {:noreply, clear_host_grace(state)}
    else
      Logger.info("[WatchParty] Room #{state.room_id} host grace expired")
      state = end_persisted_room(state, "host_disconnected")
      {:stop, :normal, state}
    end
  end

  def handle_info({:host_grace_expired, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _owner_pid, _reason}, state) do
    case Map.get(state.monitor_connections, monitor_ref) do
      nil ->
        {:noreply, state}

      {user_id, connection_id} ->
        state =
          state
          |> remove_connection(user_id, connection_id, demonitor?: false)
          |> touch_activity()

        {state, departure} = finish_connection_departure(state, user_id)
        state = persist_snapshot(state, true)

        if not departure.user_connected? do
          mark_participant_left(state.room_id, user_id, state.persist?)
          broadcast(state.room_id, {:participant_left, user_id})
        end

        if departure.room_empty? do
          Logger.info("[WatchParty] Room #{state.room_id} lost its last connection")
        end

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Snapshot loading and persistence ---

  defp load_snapshot(opts, false) do
    {:ok,
     %{
       room_id: Keyword.fetch!(opts, :room_id),
       host_user_id: Keyword.fetch!(opts, :host_user_id),
       catalog_item_id: Keyword.fetch!(opts, :catalog_item_id),
       source_type: Keyword.get(opts, :source_type),
       source_id: Keyword.get(opts, :source_id),
       playback_state: Keyword.get(opts, :playback_state, "paused"),
       playback_position: Keyword.get(opts, :playback_position, 0.0),
       playback_buffering: Keyword.get(opts, :playback_buffering, false),
       playback_version: Keyword.get(opts, :playback_version, 0),
       playback_updated_at: Keyword.get(opts, :playback_updated_at),
       last_activity_at: Keyword.get(opts, :last_activity_at)
     }}
  end

  defp load_snapshot(opts, true) do
    case Repo.get(Room, Keyword.fetch!(opts, :room_id)) do
      %Room{status: "active"} = room -> {:ok, room}
      _ -> {:error, :room_inactive}
    end
  end

  defp snapshot_room_id(%Room{id: room_id}), do: room_id
  defp snapshot_room_id(%{room_id: room_id}), do: room_id

  defp restore_playback(snapshot) do
    playback_state = if snapshot.playback_state == "playing", do: :playing, else: :paused
    buffering = snapshot.playback_buffering == true
    position = finite_position(snapshot.playback_position)

    elapsed =
      if playback_state == :playing and not buffering and snapshot.playback_updated_at do
        max(0, DateTime.diff(DateTime.utc_now(), snapshot.playback_updated_at, :millisecond)) /
          1_000.0
      else
        0.0
      end

    %{
      state: playback_state,
      position: position + elapsed,
      host_buffering: buffering,
      updated_at: now()
    }
  end

  defp persist_snapshot(%{persist?: false} = state, _force?), do: state

  defp persist_snapshot(state, force?) do
    if force? or now() - state.last_persisted_at >= @snapshot_interval do
      playback = compute_current_playback(state.playback)
      timestamp = DateTime.utc_now()

      {_, _} =
        from(room in Room,
          where: room.id == ^state.room_id and room.status == "active",
          where: room.playback_version <= ^state.version
        )
        |> Repo.update_all(
          set: [
            catalog_item_id: state.catalog_item_id,
            source_type: state.source_type,
            source_id: state.source_id,
            playback_state: Atom.to_string(playback.state),
            playback_position: playback.position,
            playback_buffering: playback.host_buffering,
            playback_version: state.version,
            playback_updated_at: timestamp,
            last_activity_at: state.activity_updated_at,
            updated_at: DateTime.utc_now(:second)
          ]
        )

      %{state | last_persisted_at: now()}
    else
      state
    end
  rescue
    error ->
      Logger.warning(
        "[WatchParty] Room #{state.room_id} snapshot persistence failed: #{Exception.message(error)}"
      )

      state
  end

  defp end_persisted_room(state, reason) do
    if state.persist? do
      case Repo.get(Room, state.room_id) do
        %Room{status: "active"} = room ->
          room
          |> Room.end_changeset(reason)
          |> Repo.update()

        _ ->
          :ok
      end

      mark_participants_left(state.room_id)
    end

    broadcast(state.room_id, {:room_ended, reason})
    emit(:room_ended, %{count: 1}, %{room_id: state.room_id, reason: reason})
    state
  rescue
    error ->
      Logger.error(
        "[WatchParty] Room #{state.room_id} failed to persist end state: #{Exception.message(error)}"
      )

      broadcast(state.room_id, {:room_ended, reason})
      state
  end

  # --- Connection and host lifecycle ---

  defp put_connection(state, user_id, connection_id, owner_pid) do
    key = {user_id, connection_id}

    state =
      case Map.get(state.connection_monitors, key) do
        %{owner_pid: ^owner_pid} -> state
        _monitor -> drop_connection_monitor(state, key, true)
      end

    {connection_monitors, monitor_connections} =
      if Map.has_key?(state.connection_monitors, key) do
        {state.connection_monitors, state.monitor_connections}
      else
        monitor_ref = Process.monitor(owner_pid)

        {
          Map.put(state.connection_monitors, key, %{owner_pid: owner_pid, ref: monitor_ref}),
          Map.put(state.monitor_connections, monitor_ref, key)
        }
      end

    connections =
      Map.update(state.connections, user_id, MapSet.new([connection_id]), fn connection_ids ->
        MapSet.put(connection_ids, connection_id)
      end)

    %{
      state
      | connections: connections,
        connection_monitors: connection_monitors,
        monitor_connections: monitor_connections
    }
  end

  defp remove_connection(state, user_id, connection_id, opts \\ []) do
    demonitor? = Keyword.get(opts, :demonitor?, true)
    key = {user_id, connection_id}
    state = drop_connection_monitor(state, key, demonitor?)

    connections =
      case Map.get(state.connections, user_id) do
        nil ->
          state.connections

        connection_ids ->
          remaining = MapSet.delete(connection_ids, connection_id)

          if MapSet.size(remaining) == 0 do
            Map.delete(state.connections, user_id)
          else
            Map.put(state.connections, user_id, remaining)
          end
      end

    %{state | connections: connections}
  end

  defp drop_connection_monitor(state, key, demonitor?) do
    case Map.pop(state.connection_monitors, key) do
      {nil, _connection_monitors} ->
        state

      {%{ref: monitor_ref}, connection_monitors} ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])

        %{
          state
          | connection_monitors: connection_monitors,
            monitor_connections: Map.delete(state.monitor_connections, monitor_ref)
        }
    end
  end

  defp recover_connection(state, user_id, connection_id, owner_pid) do
    cond do
      connected_connection?(state, user_id, connection_id) ->
        put_connection(state, user_id, connection_id, owner_pid)

      valid_connection?(user_id, connection_id, owner_pid) and state.persist? and
          active_participant?(state.room_id, user_id) ->
        host_was_offline = user_id == state.host_user_id and not connected_user?(state, user_id)

        state =
          state
          |> put_connection(user_id, connection_id, owner_pid)
          |> touch_activity()
          |> maybe_cancel_host_grace(user_id)
          |> maybe_schedule_host_grace()

        if host_was_offline do
          broadcast(state.room_id, {:host_status, :online})
        end

        emit(:participant_reconnected, %{count: 1}, %{
          room_id: state.room_id,
          role: if(user_id == state.host_user_id, do: :host, else: :viewer)
        })

        state

      true ->
        state
    end
  end

  defp finish_connection_departure(state, user_id) do
    user_connected? = connected_user?(state, user_id)

    state =
      if user_connected? do
        state
      else
        %{state | participant_states: Map.delete(state.participant_states, user_id)}
      end

    state =
      if user_id == state.host_user_id and not user_connected? do
        state
        |> pause_for_host_absence()
        |> maybe_schedule_host_grace()
      else
        state
      end

    {state, %{user_connected?: user_connected?, room_empty?: connection_count(state) == 0}}
  end

  defp connected_user?(state, user_id), do: Map.has_key?(state.connections, user_id)

  defp connected_connection?(state, user_id, connection_id) do
    case Map.get(state.connections, user_id) do
      %MapSet{} = connection_ids -> MapSet.member?(connection_ids, connection_id)
      _ -> false
    end
  end

  defp host_connection?(state, user_id, connection_id) do
    user_id == state.host_user_id and connected_connection?(state, user_id, connection_id)
  end

  defp valid_connection?(user_id, connection_id, owner_pid) do
    is_integer(user_id) and user_id > 0 and is_pid(owner_pid) and is_binary(connection_id) and
      byte_size(connection_id) > 0 and byte_size(connection_id) <= @max_connection_id_bytes
  end

  defp participant_count(state), do: map_size(state.connections)

  defp connection_count(state) do
    Enum.reduce(state.connections, 0, fn {_user_id, connection_ids}, total ->
      total + MapSet.size(connection_ids)
    end)
  end

  defp maybe_schedule_host_grace(state) do
    cond do
      connected_user?(state, state.host_user_id) ->
        state

      participant_count(state) == 0 ->
        state

      state.host_grace_timer ->
        state

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:host_grace_expired, ref}, @host_grace_timeout)
        broadcast(state.room_id, {:host_status, :offline})
        %{state | host_grace_timer: timer, host_grace_ref: ref}
    end
  end

  defp maybe_cancel_host_grace(state, user_id) when user_id == state.host_user_id do
    cancel_timer(state.host_grace_timer)
    clear_host_grace(state)
  end

  defp maybe_cancel_host_grace(state, _user_id), do: state

  defp clear_host_grace(state),
    do: %{state | host_grace_timer: nil, host_grace_ref: nil}

  defp pause_for_host_absence(state) do
    playback = compute_current_playback(state.playback)

    state =
      %{state | playback: paused_playback(playback.position)}
      |> touch_activity()
      |> broadcast_action(%{"action" => "pause", "reason" => "host_disconnected"})

    persist_snapshot(state, true)
  end

  # --- Beacon and synchronization ---

  defp reconcile_host_beacon(state, position, participant_state, buffering) do
    previous = compute_current_playback(state.playback)
    playback_state = if participant_state == "playing", do: :playing, else: :paused

    playback = %{
      state: playback_state,
      position: position,
      host_buffering: buffering,
      updated_at: now()
    }

    state = %{state | playback: playback} |> bump_version()

    if previous.state != playback_state or previous.host_buffering != buffering do
      broadcast_periodic_sync(state)
    else
      state
    end
  end

  defp maybe_resync_viewer(state, _user_id, _position, true), do: state

  defp maybe_resync_viewer(state, user_id, position, false) do
    playback = compute_current_playback(state.playback)
    drift = abs(position - playback.position)

    cond do
      drift > @drift_resync_threshold ->
        Logger.warning(
          "[WatchParty] Room #{state.room_id}: user #{user_id} drift #{Float.round(drift, 2)}s — pushing resync"
        )

        state = bump_version(state)

        broadcast(state.room_id, {
          :resync_user,
          sync_payload(state, playback)
          |> Map.put(:target_user_id, user_id)
        })

        emit(:drift_resync, %{drift_seconds: drift}, %{room_id: state.room_id})
        state

      drift > @max_drift_log ->
        Logger.warning(
          "[WatchParty] Room #{state.room_id}: user #{user_id} drift #{Float.round(drift, 2)}s"
        )

        state

      true ->
        state
    end
  end

  defp broadcast_periodic_sync(state) do
    state = bump_version(state)
    playback = compute_current_playback(state.playback)
    broadcast(state.room_id, {:sync_command, sync_payload(state, playback)})
    state
  end

  defp broadcast_action(state, action) do
    state = bump_version(state)
    playback = compute_current_playback(state.playback)
    system_time = System.system_time(:millisecond)

    payload =
      sync_payload(state, playback)
      |> Map.put(:type, action["action"])
      |> Map.put(:target_time, system_time + @command_lead_ms)
      |> maybe_put_reason(action["reason"])

    broadcast(state.room_id, {:sync_command, payload})
    state
  end

  defp sync_payload(state, playback) do
    %{
      type: "sync",
      state: Atom.to_string(playback.state),
      position: playback.position,
      host_buffering: playback.host_buffering,
      sequence: state.version,
      server_time: System.system_time(:millisecond)
    }
  end

  defp maybe_put_reason(payload, nil), do: payload
  defp maybe_put_reason(payload, reason), do: Map.put(payload, :reason, reason)

  defp broadcast_needed?(state) do
    state.playback.state == :playing or state.playback.host_buffering or recently_active?(state)
  end

  defp recently_active?(state), do: now() - state.last_activity < :timer.seconds(15)

  # --- Playback state ---

  defp handle_host_playback_action(state, action) do
    case apply_action(state, action) do
      {:ok, next_state} ->
        next_state =
          next_state
          |> broadcast_action(action)
          |> persist_snapshot(true)

        emit(:playback_action, %{count: 1}, %{
          room_id: state.room_id,
          action: action["action"]
        })

        {:reply, :ok, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_action(state, %{"action" => "play", "position" => position}) do
    with {:ok, position} <- normalize_position(position) do
      {:ok,
       state
       |> Map.put(:playback, %{
         state: :playing,
         position: position,
         host_buffering: false,
         updated_at: now()
       })
       |> touch_activity()}
    end
  end

  defp apply_action(state, %{"action" => "pause", "position" => position}) do
    with {:ok, position} <- normalize_position(position) do
      {:ok, state |> Map.put(:playback, paused_playback(position)) |> touch_activity()}
    end
  end

  defp apply_action(state, %{"action" => "seek", "position" => position}) do
    with {:ok, position} <- normalize_position(position) do
      current = compute_current_playback(state.playback)

      {:ok,
       state
       |> Map.put(:playback, %{
         current
         | position: position,
           updated_at: now(),
           host_buffering: false
       })
       |> touch_activity()}
    end
  end

  defp apply_action(_state, _action), do: {:error, :invalid_playback_action}

  defp compute_current_playback(%{state: :playing, host_buffering: false} = playback) do
    elapsed = max(0, now() - playback.updated_at) / 1_000.0
    %{playback | position: playback.position + elapsed}
  end

  defp compute_current_playback(playback), do: playback

  defp paused_playback(position) do
    %{
      state: :paused,
      position: finite_position(position),
      host_buffering: false,
      updated_at: now()
    }
  end

  defp normalize_position(value)
       when is_integer(value) and value >= 0 and value <= @max_position_seconds,
       do: {:ok, value * 1.0}

  defp normalize_position(value)
       when is_float(value) and value >= 0 and value <= @max_position_seconds,
       do: {:ok, value}

  defp normalize_position(_value), do: {:error, :invalid_playback_action}

  defp finite_position(value) do
    case normalize_position(value) do
      {:ok, position} -> position
      {:error, _reason} -> 0.0
    end
  end

  defp valid_beacon?(position, participant_state, buffering) do
    match?({:ok, _position}, normalize_position(position)) and
      participant_state in ~w(playing paused) and is_boolean(buffering)
  end

  defp valid_content_ref?(catalog_item_id, source_type, source_id) do
    is_integer(catalog_item_id) and catalog_item_id > 0 and
      source_type in ~w(live_channel movie episode gindex gindex_episode torrent) and
      is_integer(source_id) and source_id > 0
  end

  defp active_participant?(room_id, user_id) do
    from(participant in Participant,
      where:
        participant.room_id == ^room_id and participant.user_id == ^user_id and
          is_nil(participant.left_at),
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  rescue
    _error -> false
  end

  defp mark_participant_left(_room_id, _user_id, false), do: :ok

  defp mark_participant_left(room_id, user_id, true) do
    timestamp = DateTime.utc_now(:second)

    from(participant in Participant,
      where:
        participant.room_id == ^room_id and participant.user_id == ^user_id and
          is_nil(participant.left_at)
    )
    |> Repo.update_all(set: [left_at: timestamp, updated_at: timestamp])

    :ok
  rescue
    _error -> :ok
  end

  defp mark_participants_left(room_id) do
    timestamp = DateTime.utc_now(:second)

    from(participant in Participant,
      where: participant.room_id == ^room_id and is_nil(participant.left_at)
    )
    |> Repo.update_all(set: [left_at: timestamp, updated_at: timestamp])

    :ok
  end

  defp snapshot_activity_updated_at(%{last_activity_at: %DateTime{} = timestamp}), do: timestamp
  defp snapshot_activity_updated_at(_snapshot), do: DateTime.utc_now()

  defp restore_monotonic_activity(activity_updated_at, monotonic_now) do
    elapsed = max(0, DateTime.diff(DateTime.utc_now(), activity_updated_at, :millisecond))
    monotonic_now - elapsed
  end

  defp touch_activity(state) do
    %{state | last_activity: now(), activity_updated_at: DateTime.utc_now()}
  end

  defp bump_version(state), do: %{state | version: state.version + 1}

  # --- Timers, PubSub, telemetry ---

  defp schedule_sync_broadcast,
    do: Process.send_after(self(), :sync_broadcast, @sync_interval)

  defp schedule_idle_check,
    do: Process.send_after(self(), :idle_check, @idle_check_interval)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp broadcast(room_id, message),
    do: Phoenix.PubSub.broadcast(Streamix.PubSub, "watch_party:room:#{room_id}", message)

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:streamix, :watch_party, event], measurements, metadata)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
