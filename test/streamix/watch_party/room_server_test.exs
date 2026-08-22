defmodule Streamix.WatchParty.RoomServerTest do
  use ExUnit.Case, async: true

  alias Streamix.WatchParty
  alias Streamix.WatchParty.RoomServer

  test "uses a transient child and starts without phantom participants" do
    opts = room_server_opts()
    child_spec = RoomServer.child_spec(opts)

    assert child_spec.restart == :transient

    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server(opts)

    assert RoomServer.whereis(room_id) == pid
    assert :sys.get_state(pid).connections == %{}

    assert {:ok, %{state: :paused, position: joined_position}} =
             RoomServer.join(room_id, host_user_id, "host-tab")

    assert {:ok, %{state: :paused, position: current_position}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert_in_delta joined_position, 0.0, 0.001
    assert_in_delta current_position, 0.0, 0.001
    assert :sys.get_state(pid).connections == %{host_user_id => MapSet.new(["host-tab"])}
  end

  test "only an active host connection controls playback and commands are sequenced" do
    %{room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    assert {:ok, _} = RoomServer.join(room_id, 202, "viewer-tab")

    assert {:error, :not_host} =
             RoomServer.playback_action(room_id, 202, "viewer-tab", %{
               "action" => "play",
               "position" => 12.5
             })

    before_command = System.system_time(:millisecond)

    assert :ok =
             RoomServer.playback_action(room_id, host_user_id, "host-tab", %{
               "action" => "play",
               "position" => 12.5
             })

    assert_receive {:sync_command,
                    %{
                      type: "play",
                      position: position,
                      sequence: sequence,
                      server_time: server_time,
                      target_time: target_time
                    }}

    assert position >= 12.5
    assert sequence > 0
    assert server_time >= before_command
    assert target_time > server_time

    assert {:ok, %{state: :playing, position: current_position}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert current_position >= position
  end

  test "large viewer drift produces a usable targeted sync command" do
    viewer_id = 202
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    assert {:ok, _} = RoomServer.join(room_id, viewer_id, "viewer-tab")

    assert :ok =
             RoomServer.playback_action(room_id, host_user_id, "host-tab", %{
               "action" => "seek",
               "position" => 10.0
             })

    assert_receive {:sync_command, %{type: "seek", sequence: action_sequence}}

    assert :ok =
             RoomServer.sync_beacon(
               room_id,
               viewer_id,
               "viewer-tab",
               20.0,
               "playing",
               false,
               123
             )

    room_state = :sys.get_state(pid)

    assert %{position: 20.0, state: "playing", buffering: false} =
             room_state.participant_states[viewer_id]

    assert_receive {:resync_user,
                    %{
                      type: "sync",
                      target_user_id: ^viewer_id,
                      state: "paused",
                      position: position,
                      sequence: sequence,
                      server_time: server_time
                    }}

    assert_in_delta position, 10.0, 0.01
    assert sequence > action_sequence
    assert is_integer(server_time)
  end

  test "host beacons freeze the shared timeline while buffering and resume it afterward" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    assert {:ok, _} = RoomServer.join(room_id, 202, "viewer-tab")

    assert :ok =
             RoomServer.playback_action(room_id, host_user_id, "host-tab", %{
               "action" => "play",
               "position" => 10.0
             })

    assert_receive {:sync_command, %{type: "play"}}

    assert :ok =
             RoomServer.sync_beacon(
               room_id,
               host_user_id,
               "host-tab",
               12.0,
               "playing",
               true,
               1
             )

    _barrier = :sys.get_state(pid)
    assert_receive {:sync_command, %{type: "sync", host_buffering: true}}

    :sys.replace_state(pid, fn state ->
      put_in(state.playback.updated_at, System.monotonic_time(:millisecond) - 5_000)
    end)

    assert {:ok, %{position: buffered_position, host_buffering: true}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert_in_delta buffered_position, 12.0, 0.001

    assert :ok =
             RoomServer.sync_beacon(
               room_id,
               host_user_id,
               "host-tab",
               12.0,
               "playing",
               false,
               2
             )

    _barrier = :sys.get_state(pid)
    assert_receive {:sync_command, %{type: "sync", host_buffering: false}}

    :sys.replace_state(pid, fn state ->
      put_in(state.playback.updated_at, System.monotonic_time(:millisecond) - 2_000)
    end)

    assert {:ok, %{position: resumed_position, host_buffering: false}, ^host_user_id} =
             RoomServer.get_state(room_id)

    assert resumed_position >= 13.9
  end

  test "one tab leaving does not evict the same user from another tab" do
    %{pid: pid, room_id: room_id} = start_room_server()

    assert {:ok, _} = RoomServer.join(room_id, 202, "tab-a")
    assert {:ok, _} = RoomServer.join(room_id, 202, "tab-b")

    assert {:ok, %{user_connected?: true, room_empty?: false}} =
             RoomServer.leave(room_id, 202, "tab-a")

    assert :sys.get_state(pid).connections[202] == MapSet.new(["tab-b"])

    assert {:ok, %{user_connected?: false, room_empty?: true}} =
             RoomServer.leave(room_id, 202, "tab-b")

    refute Map.has_key?(:sys.get_state(pid).connections, 202)
  end

  test "a crashed browser owner releases its connection without relying on LiveView terminate" do
    viewer_id = 202
    %{pid: pid, room_id: room_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))
    test_pid = self()

    owner_pid =
      spawn(fn ->
        send(test_pid, {:joined, RoomServer.join(room_id, viewer_id, "viewer-tab")})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:joined, {:ok, _playback}}
    assert :sys.get_state(pid).connections[viewer_id] == MapSet.new(["viewer-tab"])

    Process.exit(owner_pid, :kill)

    assert_receive {:participant_left, ^viewer_id}
    refute Map.has_key?(:sys.get_state(pid).connections, viewer_id)
    assert Process.alive?(pid)
  end

  test "a transient node partition fences a connection and a later beacon restores its monitor" do
    viewer_id = 202
    connection_id = "viewer-tab"
    %{pid: pid, room_id: room_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, viewer_id, connection_id)

    state = :sys.get_state(pid)
    old_monitor = state.connection_monitors[{viewer_id, connection_id}].ref
    send(pid, {:DOWN, old_monitor, :process, self(), :noconnection})

    fenced = :sys.get_state(pid)
    assert fenced.connections[viewer_id] == MapSet.new([connection_id])
    assert Map.has_key?(fenced.connection_fences, {viewer_id, connection_id})
    refute Map.has_key?(fenced.connection_monitors, {viewer_id, connection_id})
    refute_receive {:participant_left, ^viewer_id}

    assert :ok =
             RoomServer.sync_beacon(
               room_id,
               viewer_id,
               connection_id,
               15.0,
               "playing",
               false,
               1
             )

    recovered = :sys.get_state(pid)
    refute Map.has_key?(recovered.connection_fences, {viewer_id, connection_id})
    assert recovered.connection_monitors[{viewer_id, connection_id}].ref != old_monitor
    assert recovered.participant_states[viewer_id].position == 15.0
    refute_receive {:participant_left, ^viewer_id}
  end

  test "an unrecovered node partition expires its fence before host grace starts" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    assert {:ok, _} = RoomServer.join(room_id, 202, "viewer-tab")

    state = :sys.get_state(pid)
    old_monitor = state.connection_monitors[{host_user_id, "host-tab"}].ref
    send(pid, {:DOWN, old_monitor, :process, self(), :noconnection})

    fenced = :sys.get_state(pid)
    assert fenced.connections[host_user_id] == MapSet.new(["host-tab"])
    assert fenced.host_grace_ref == nil
    refute_receive {:host_status, :offline}

    %{ref: fence_ref} = fenced.connection_fences[{host_user_id, "host-tab"}]
    send(pid, {:connection_fence_expired, {host_user_id, "host-tab"}, fence_ref})

    expired = :sys.get_state(pid)
    refute Map.has_key?(expired.connections, host_user_id)
    assert is_reference(expired.host_grace_ref)
    assert_receive {:sync_command, %{type: "pause", reason: "host_disconnected"}}
    assert_receive {:host_status, :offline}
  end

  test "malformed playback actions and beacons are ignored without crashing the room" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")

    assert {:error, :invalid_playback_action} =
             RoomServer.playback_action(room_id, host_user_id, "host-tab", %{
               "action" => "play",
               "position" => "not-a-number"
             })

    assert :ok =
             RoomServer.sync_beacon(
               room_id,
               host_user_id,
               "host-tab",
               "not-a-number",
               "invalid",
               "invalid",
               0
             )

    state = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert state.participant_states == %{}
    assert state.playback.state == :paused
  end

  test "periodic sync requires at least two connected users" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    send(pid, :sync_broadcast)
    refute_receive {:sync_command, _payload}

    assert {:ok, _} = RoomServer.join(room_id, 202, "viewer-tab")
    send(pid, :sync_broadcast)

    assert_receive {:sync_command,
                    %{
                      type: "sync",
                      state: "paused",
                      position: sync_position,
                      sequence: sequence,
                      server_time: server_time
                    }}

    assert_in_delta sync_position, 0.0, 0.001
    assert sequence > 0
    assert is_integer(server_time)
  end

  test "host content transitions are authoritative room events" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")

    assert {:ok, version} =
             RoomServer.change_content(room_id, host_user_id, "host-tab", %{
               catalog_item_id: 901,
               source_type: "episode",
               source_id: 902
             })

    assert_receive {:content_changed,
                    %{
                      catalog_item_id: 901,
                      source_type: "episode",
                      source_id: 902,
                      version: ^version
                    }}

    state = :sys.get_state(pid)
    assert state.catalog_item_id == 901
    assert state.source_type == "episode"
    assert state.source_id == 902
    assert state.playback.state == :paused
    assert_in_delta state.playback.position, 0.0, 0.001
  end

  test "host grace expiry ends a room that still has viewers" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))
    monitor = Process.monitor(pid)

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")
    assert {:ok, _} = RoomServer.join(room_id, 202, "viewer-tab")

    assert {:ok, %{user_connected?: false, room_empty?: false}} =
             RoomServer.leave(room_id, host_user_id, "host-tab")

    assert_receive {:sync_command, %{type: "pause", reason: "host_disconnected"}}
    assert_receive {:host_status, :offline}

    %{host_grace_ref: ref} = :sys.get_state(pid)
    send(pid, {:host_grace_expired, ref})

    assert_receive {:room_ended, "host_disconnected"}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert RoomServer.whereis(room_id) == nil
  end

  test "an empty room terminates normally after its idle deadline" do
    %{pid: pid, room_id: room_id, host_user_id: host_user_id} = start_room_server()
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room_id))
    monitor = Process.monitor(pid)

    assert {:ok, _} = RoomServer.join(room_id, host_user_id, "host-tab")

    assert {:ok, %{room_empty?: true}} =
             RoomServer.leave(room_id, host_user_id, "host-tab")

    :sys.replace_state(pid, fn state ->
      %{state | last_activity: System.monotonic_time(:millisecond) - :timer.minutes(5) - 1}
    end)

    send(pid, :idle_check)

    assert_receive {:room_ended, "idle_timeout"}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert RoomServer.whereis(room_id) == nil
  end

  defp start_room_server(opts \\ room_server_opts()) do
    pid = start_supervised!({RoomServer, opts})

    %{
      pid: pid,
      room_id: Keyword.fetch!(opts, :room_id),
      host_user_id: Keyword.fetch!(opts, :host_user_id)
    }
  end

  defp room_server_opts do
    [
      room_id: System.unique_integer([:positive]),
      host_user_id: System.unique_integer([:positive]),
      catalog_item_id: System.unique_integer([:positive]),
      source_type: "movie",
      source_id: System.unique_integer([:positive]),
      persist?: false
    ]
  end
end
