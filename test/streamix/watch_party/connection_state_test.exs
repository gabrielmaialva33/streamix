defmodule Streamix.WatchParty.ConnectionStateTest do
  use ExUnit.Case, async: true

  alias Streamix.WatchParty.ConnectionState

  test "tracks users and browser connections without duplicates" do
    connections =
      %{}
      |> ConnectionState.put(10, "tab-a")
      |> ConnectionState.put(10, "tab-a")
      |> ConnectionState.put(10, "tab-b")
      |> ConnectionState.put(20, "phone")

    assert ConnectionState.user_connected?(connections, 10)
    assert ConnectionState.connection_connected?(connections, 10, "tab-a")
    refute ConnectionState.connection_connected?(connections, 10, "missing")
    assert ConnectionState.participant_count(connections) == 2
    assert ConnectionState.connection_count(connections) == 3
  end

  test "removes only the requested connection and drops empty user buckets" do
    connections =
      %{}
      |> ConnectionState.put(10, "tab-a")
      |> ConnectionState.put(10, "tab-b")

    connections = ConnectionState.delete(connections, 10, "tab-a")
    assert ConnectionState.user_connected?(connections, 10)
    refute ConnectionState.connection_connected?(connections, 10, "tab-a")
    assert ConnectionState.connection_connected?(connections, 10, "tab-b")

    connections = ConnectionState.delete(connections, 10, "tab-b")
    refute ConnectionState.user_connected?(connections, 10)
    assert connections == %{}
  end

  test "validates the complete connection identity boundary" do
    owner_pid = self()

    assert ConnectionState.valid_identity?(1, "connection", owner_pid)
    assert ConnectionState.valid_identity?(1, String.duplicate("a", 128), owner_pid)

    refute ConnectionState.valid_identity?(0, "connection", owner_pid)
    refute ConnectionState.valid_identity?(1, "", owner_pid)
    refute ConnectionState.valid_identity?(1, String.duplicate("a", 129), owner_pid)
    refute ConnectionState.valid_identity?(1, :connection, owner_pid)
    refute ConnectionState.valid_identity?(1, "connection", :not_a_pid)
  end

  test "derives participant and host lifecycle after the last connection leaves" do
    participant_states = %{10 => %{position: 20.0}, 20 => %{position: 5.0}}

    still_connected =
      %{}
      |> ConnectionState.put(10, "tab-b")
      |> ConnectionState.departure(participant_states, 10, 10)

    assert still_connected.user_connected?
    refute still_connected.host_disconnected?
    refute still_connected.room_empty?
    assert still_connected.participant_states == participant_states

    disconnected = ConnectionState.departure(%{}, participant_states, 10, 10)

    refute disconnected.user_connected?
    assert disconnected.host_disconnected?
    assert disconnected.room_empty?
    assert disconnected.participant_states == %{20 => %{position: 5.0}}
  end
end
