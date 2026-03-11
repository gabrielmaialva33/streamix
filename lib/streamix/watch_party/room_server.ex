defmodule Streamix.WatchParty.RoomServer do
  @moduledoc """
  GenServer managing real-time playback state for a Watch Party room.

  Uses leader-follower protocol:
  - Host controls playback (play/pause/seek)
  - Followers adjust their position via sync commands
  - Drift correction: <40ms ignore, <2s playbackRate, >2s force seek
  """
  use GenServer

  require Logger

  @sync_interval :timer.seconds(5)
  @idle_check_interval :timer.seconds(60)
  @idle_timeout :timer.minutes(5)

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

  def sync_beacon(room_id, user_id, position, client_time) do
    GenServer.cast(via(room_id), {:sync_beacon, user_id, position, client_time})
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
    content_type = Keyword.fetch!(opts, :content_type)
    content_id = Keyword.fetch!(opts, :content_id)

    schedule_sync_broadcast()
    schedule_idle_check()

    state = %{
      room_id: room_id,
      host_user_id: host_user_id,
      content_type: content_type,
      content_id: content_id,
      playback: %{
        state: :paused,
        position: 0.0,
        updated_at: System.monotonic_time(:millisecond)
      },
      participants: MapSet.new([host_user_id]),
      last_activity: System.monotonic_time(:millisecond)
    }

    Logger.info("[WatchParty] Room #{room_id} started (host: #{host_user_id})")

    {:ok, state}
  end

  @impl true
  def handle_call({:join, user_id}, _from, state) do
    state = %{state | participants: MapSet.put(state.participants, user_id), last_activity: now()}
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
    # Calculate current position based on elapsed time
    playback = compute_current_playback(state.playback)
    {:reply, {:ok, playback, state.host_user_id}, state}
  end

  @impl true
  def handle_cast({:leave, user_id}, state) do
    state = %{state | participants: MapSet.delete(state.participants, user_id)}

    if MapSet.size(state.participants) == 0 do
      Logger.info("[WatchParty] Room #{state.room_id} empty, will idle-terminate")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_beacon, _user_id, _position, _client_time}, state) do
    # Track participant position for drift detection
    # The actual drift correction happens client-side via sync broadcasts
    {:noreply, %{state | last_activity: now()}}
  end

  @impl true
  def handle_info(:sync_broadcast, state) do
    schedule_sync_broadcast()

    if MapSet.size(state.participants) > 0 do
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
    schedule_idle_check()

    idle_ms = now() - state.last_activity

    if MapSet.size(state.participants) == 0 && idle_ms > @idle_timeout do
      Logger.info("[WatchParty] Room #{state.room_id} idle timeout, shutting down")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # --- Private ---

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
    elapsed = (now() - updated_at) / 1000.0
    %{state: :playing, position: pos + elapsed, updated_at: updated_at}
  end

  defp compute_current_playback(playback), do: playback

  defp broadcast_sync_command(state, action) do
    playback = compute_current_playback(state.playback)
    # Add 300ms delay for network jitter compensation
    target_time = System.system_time(:millisecond) + 300

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
