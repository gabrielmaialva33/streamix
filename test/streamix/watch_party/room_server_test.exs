defmodule Streamix.WatchParty.RoomServerTest do
  use ExUnit.Case, async: true

  alias Streamix.WatchParty
  alias Streamix.WatchParty.RoomServer

  test "starts paused with the host present and returns current state to joiners" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()

    assert RoomServer.whereis(room_id) == pid

    assert {:ok, %{state: :paused, position: joined_position}} = RoomServer.join(room_id, 202)

    assert {:ok, %{state: :paused, position: current_position}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert_in_delta joined_position, 0.0, 0.001
    assert_in_delta current_position, 0.0, 0.001

    assert :sys.get_state(pid).participants == MapSet.new([host_user_id, 202])
  end

  test "only the host can control playback and commands include timing metadata" do
    %{room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:error, :not_host} =
             RoomServer.playback_action(room_id, 202, %{
               "action" => "play",
               "position" => 12.5
             })

    assert {:ok, %{state: :paused, position: paused_position}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert_in_delta paused_position, 0.0, 0.001

    before_command = System.system_time(:millisecond)

    assert :ok =
             RoomServer.playback_action(room_id, host_user_id, %{
               "action" => "play",
               "position" => 12.5
             })

    assert_receive {:sync_command,
                    %{
                      type: "play",
                      position: position,
                      server_time: server_time,
                      target_time: target_time
                    }}

    assert position >= 12.5
    assert server_time >= before_command
    assert target_time >= server_time

    assert {:ok, %{state: :playing, position: current_position}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert current_position >= position
  end

  test "large viewer drift triggers a targeted resync and records the beacon" do
    viewer_id = 202
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _playback} = RoomServer.join(room_id, viewer_id)

    assert :ok =
             RoomServer.playback_action(room_id, host_user_id, %{
               "action" => "seek",
               "position" => 10.0
             })

    assert_receive {:sync_command, %{type: "seek"}}

    assert :ok = RoomServer.sync_beacon(room_id, viewer_id, 20.0, "playing", false, 123)

    assert_receive {:resync_user,
                    %{
                      user_id: ^viewer_id,
                      state: "paused",
                      position: position,
                      server_time: server_time
                    }}

    assert_in_delta position, 10.0, 0.01
    assert is_integer(server_time)

    assert {:ok, _playback, ^host_user_id} = RoomServer.get_state(room_id)

    assert %{position: 20.0, state: "playing", buffering: false} =
             :sys.get_state(pid).participant_states[viewer_id]
  end

  test "periodic sync broadcasts only after another participant joins" do
    %{pid: pid, room_id: room_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    send(pid, :sync_broadcast)
    refute_receive {:sync_command, _payload}

    assert {:ok, _playback} = RoomServer.join(room_id, 202)
    send(pid, :sync_broadcast)

    assert_receive {:sync_command,
                    %{
                      type: "sync",
                      state: "paused",
                      position: sync_position,
                      server_time: server_time
                    }}

    assert_in_delta sync_position, 0.0, 0.001
    assert is_integer(server_time)
  end

  test "an empty room terminates after its idle deadline" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    monitor = Process.monitor(pid)

    RoomServer.leave(room_id, host_user_id)
    _state_after_leave = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | last_activity: System.monotonic_time(:millisecond) - :timer.minutes(5) - 1}
    end)

    send(pid, :idle_check)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    # Registry removes dead entries asynchronously. The process monitor is the
    # authoritative shutdown signal; a briefly stale lookup must never resolve
    # to another live room process.
    case RoomServer.whereis(room_id) do
      nil -> :ok
      registered_pid -> refute Process.alive?(registered_pid)
    end
  end

  defp start_room_server do
    room_id = System.unique_integer([:positive])
    host_user_id = System.unique_integer([:positive])

    child_spec =
      Supervisor.child_spec(
        {RoomServer,
         room_id: room_id,
         host_user_id: host_user_id,
         catalog_item_id: System.unique_integer([:positive])},
        restart: :temporary
      )

    pid = start_supervised!(child_spec)

    %{pid: pid, room_id: room_id, host_user_id: host_user_id}
  end
end
