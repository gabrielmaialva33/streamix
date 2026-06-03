defmodule Streamix.WatchParty.RoomServer do
  @moduledoc """
  GenServer managing real-time playback state for a Watch Party room.

  v2 — Enhanced sync protocol:
  - Server-authoritative time for clock offset estimation
  - Per-participant drift tracking from sync beacons
  - Adaptive sync broadcast (faster during catchup)
  - Immediate sync on join
  """
  use GenServer

  require Logger

  @sync_interval :timer.seconds(5)
  @idle_check_interval :timer.seconds(60)
  @idle_timeout :timer.minutes(5)
  @max_drift_log 2.0
  # Above this drift we don't just log — we actively push a corrective
  # resync targeted at that viewer. Tuned so brief network jitter
  # (250–500 ms one-way) doesn't trigger seek-storms but a real out-of-
  # sync state (3 s+) gets recovered without waiting for the next round.
  @drift_resync_threshold 3.0

  # --- Public API ---

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  def join(room_id, user_id) do
    GenServer.call(via(room_id), {:join, user_id})
  end

  def leave(room_id, user_id) do
    GenServer.cast(via(room_id), {:leave, user_id})
  end

  def playback_action(room_id, user_id, action) do
    GenServer.call(via(room_id), {:playback_action, user_id, action})
  end

  def sync_beacon(room_id, user_id, position, state, buffering, client_time) do
    GenServer.cast(
      via(room_id),
      {:sync_beacon, user_id, position, state, buffering, client_time}
    )
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :get_state)
  end

  def whereis(room_id) do
    case Registry.lookup(Streamix.WatchParty.Registry, room_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(room_id) do
    {:via, Registry, {Streamix.WatchParty.Registry, room_id}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    host_user_id = Keyword.fetch!(opts, :host_user_id)
    catalog_item_id = Keyword.fetch!(opts, :catalog_item_id)

    sync_timer = schedule_sync_broadcast()
    idle_timer = schedule_idle_check()

    state = %{
      room_id: room_id,
      host_user_id: host_user_id,
      catalog_item_id: catalog_item_id,
      playback: %{
        state: :paused,
        position: 0.0,
        updated_at: System.monotonic_time(:millisecond)
      },
      participants: MapSet.new([host_user_id]),
      # Per-participant tracking: %{user_id => %{position, state, buffering, last_seen}}
      participant_states: %{},
      last_activity: System.monotonic_time(:millisecond),
      sync_timer: sync_timer,
      idle_timer: idle_timer
    }

    Logger.info("[WatchParty] Room #{room_id} started (host: #{host_user_id})")

    {:ok, state}
  end

  # Cancel scheduled timers on shutdown so a restart doesn't inherit a
  # mailbox full of stale :sync_broadcast / :idle_check messages from
  # the previous incarnation. Both Process.cancel_timer calls are no-op
  # if the timer already fired.
  @impl true
  def terminate(_reason, state) do
    if state[:sync_timer], do: Process.cancel_timer(state.sync_timer)
    if state[:idle_timer], do: Process.cancel_timer(state.idle_timer)
    :ok
  end

  @impl true
  def handle_call({:join, user_id}, _from, state) do
    state = %{
      state
      | participants: MapSet.put(state.participants, user_id),
        last_activity: now()
    }

    {:reply, {:ok, state.playback}, state}
  end

  @impl true
  def handle_call({:playback_action, user_id, action}, _from, state) do
    if user_id == state.host_user_id do
      state = apply_action(state, action)
      broadcast_sync_command(state, action)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    playback = compute_current_playback(state.playback)
    {:reply, {:ok, playback, state.host_user_id}, state}
  end

  @impl true
  def handle_cast({:leave, user_id}, state) do
    state = %{
      state
      | participants: MapSet.delete(state.participants, user_id),
        participant_states: Map.delete(state.participant_states, user_id)
    }

    if MapSet.size(state.participants) == 0 do
      Logger.info("[WatchParty] Room #{state.room_id} empty, will idle-terminate")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:sync_beacon, user_id, position, participant_state, buffering, _client_time},
        state
      ) do
    # Track per-participant state
    participant_states =
      Map.put(state.participant_states, user_id, %{
        position: position,
        state: participant_state,
        buffering: buffering,
        last_seen: now()
      })

    # Log significant drift + push targeted resync if it crosses the
    # action threshold. The host position is the source of truth; non-host
    # viewers that drift > @drift_resync_threshold get a per-user nudge
    # back into alignment instead of waiting for the next 5s broadcast.
    if user_id != state.host_user_id do
      playback = compute_current_playback(state.playback)
      drift = abs(position - playback.position)

      cond do
        drift > @drift_resync_threshold ->
          Logger.warning(
            "[WatchParty] Room #{state.room_id}: user #{user_id} drift #{Float.round(drift, 2)}s — pushing resync"
          )

          Phoenix.PubSub.broadcast(
            Streamix.PubSub,
            topic(state.room_id),
            {:resync_user,
             %{
               user_id: user_id,
               state: Atom.to_string(state.playback.state),
               position: playback.position,
               server_time: System.system_time(:millisecond)
             }}
          )

        drift > @max_drift_log ->
          Logger.warning(
            "[WatchParty] Room #{state.room_id}: user #{user_id} drift #{Float.round(drift, 2)}s"
          )

        true ->
          :ok
      end
    end

    {:noreply, %{state | participant_states: participant_states, last_activity: now()}}
  end

  @impl true
  def handle_info(:sync_broadcast, state) do
    state = %{state | sync_timer: schedule_sync_broadcast()}

    if MapSet.size(state.participants) > 1 and broadcast_needed?(state) do
      playback = compute_current_playback(state.playback)

      Phoenix.PubSub.broadcast(
        Streamix.PubSub,
        topic(state.room_id),
        {:sync_command,
         %{
           type: "sync",
           state: Atom.to_string(state.playback.state),
           position: playback.position,
           server_time: System.system_time(:millisecond)
         }}
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    state = %{state | idle_timer: schedule_idle_check()}

    idle_ms = now() - state.last_activity

    if MapSet.size(state.participants) == 0 && idle_ms > @idle_timeout do
      Logger.info("[WatchParty] Room #{state.room_id} idle timeout, shutting down")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # --- Private ---

  # Skip the periodic broadcast when nothing material has changed since
  # the last one. Paused-and-idle rooms used to push a sync_command every
  # 5 s into every viewer's mailbox forever; now they stay quiet until a
  # host action or beacon-driven resync wakes things up.
  defp broadcast_needed?(state) do
    case state.playback.state do
      :playing -> true
      _ -> recently_active?(state)
    end
  end

  defp recently_active?(state) do
    now() - state.last_activity < :timer.seconds(15)
  end

  defp apply_action(state, %{"action" => "play"} = params) do
    position = Map.get(params, "position", state.playback.position)

    %{
      state
      | playback: %{state: :playing, position: position, updated_at: now()},
        last_activity: now()
    }
  end

  defp apply_action(state, %{"action" => "pause"} = params) do
    position = Map.get(params, "position", compute_current_playback(state.playback).position)

    %{
      state
      | playback: %{state: :paused, position: position, updated_at: now()},
        last_activity: now()
    }
  end

  defp apply_action(state, %{"action" => "seek", "position" => position}) do
    %{
      state
      | playback: %{state.playback | position: position, updated_at: now()},
        last_activity: now()
    }
  end

  defp apply_action(state, _), do: state

  defp compute_current_playback(%{state: :playing, position: pos, updated_at: updated_at}) do
    # Floor at 0 to defend against monotonic-clock anomalies (suspended
    # BEAM after laptop sleep, container time jumps). A negative elapsed
    # would rewind the host's playback position for every viewer.
    elapsed = max(0, now() - updated_at) / 1000.0
    %{state: :playing, position: pos + elapsed, updated_at: updated_at}
  end

  defp compute_current_playback(playback), do: playback

  defp broadcast_sync_command(state, action) do
    playback = compute_current_playback(state.playback)
    # 200ms delay for network jitter compensation
    target_time = System.system_time(:millisecond) + 200

    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      topic(state.room_id),
      {:sync_command,
       %{
         type: action["action"],
         position: playback.position,
         server_time: System.system_time(:millisecond),
         target_time: target_time
       }}
    )
  end

  defp topic(room_id), do: "watch_party:room:#{room_id}"

  defp schedule_sync_broadcast do
    Process.send_after(self(), :sync_broadcast, @sync_interval)
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_check_interval)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
