defmodule Streamix.WatchParty.ConnectionState do
  @moduledoc """
  Pure connection-set transitions for Watch Party rooms.

  `RoomServer` owns process monitors, timers, persistence, and broadcasts. This
  module owns the deterministic shape of the browser-connection registry so
  reconnection and departure rules can be exercised without a GenServer.
  """

  @max_connection_id_bytes 128

  @type user_id :: pos_integer()
  @type connection_id :: String.t()
  @type connections :: %{optional(user_id()) => MapSet.t(connection_id())}
  @type departure :: %{
          participant_states: map(),
          user_connected?: boolean(),
          host_disconnected?: boolean(),
          room_empty?: boolean()
        }

  @doc "Adds one browser connection without duplicating an existing id."
  @spec put(connections(), user_id(), connection_id()) :: connections()
  def put(connections, user_id, connection_id) do
    Map.update(connections, user_id, MapSet.new([connection_id]), fn connection_ids ->
      MapSet.put(connection_ids, connection_id)
    end)
  end

  @doc "Removes one browser connection and drops empty user buckets."
  @spec delete(connections(), user_id(), connection_id()) :: connections()
  def delete(connections, user_id, connection_id) do
    case Map.get(connections, user_id) do
      %MapSet{} = connection_ids ->
        remaining = MapSet.delete(connection_ids, connection_id)

        if MapSet.size(remaining) == 0 do
          Map.delete(connections, user_id)
        else
          Map.put(connections, user_id, remaining)
        end

      _other ->
        connections
    end
  end

  @doc "Returns whether a user still owns at least one active connection."
  @spec user_connected?(connections(), term()) :: boolean()
  def user_connected?(connections, user_id), do: Map.has_key?(connections, user_id)

  @doc "Returns whether a specific browser connection is active."
  @spec connection_connected?(connections(), term(), term()) :: boolean()
  def connection_connected?(connections, user_id, connection_id) do
    case Map.get(connections, user_id) do
      %MapSet{} = connection_ids -> MapSet.member?(connection_ids, connection_id)
      _other -> false
    end
  end

  @doc "Counts connected users independently from their number of tabs or devices."
  @spec participant_count(connections()) :: non_neg_integer()
  def participant_count(connections), do: map_size(connections)

  @doc "Counts all active browser connections in the room."
  @spec connection_count(connections()) :: non_neg_integer()
  def connection_count(connections) do
    Enum.reduce(connections, 0, fn {_user_id, connection_ids}, total ->
      total + MapSet.size(connection_ids)
    end)
  end

  @doc "Validates the identity boundary accepted from a LiveView connection."
  @spec valid_identity?(term(), term(), term()) :: boolean()
  def valid_identity?(user_id, connection_id, owner_pid) do
    is_integer(user_id) and user_id > 0 and is_pid(owner_pid) and is_binary(connection_id) and
      byte_size(connection_id) > 0 and byte_size(connection_id) <= @max_connection_id_bytes
  end

  @doc "Derives participant cleanup and host/room lifecycle flags after a removal."
  @spec departure(connections(), map(), term(), term()) :: departure()
  def departure(connections, participant_states, host_user_id, user_id) do
    user_connected? = user_connected?(connections, user_id)

    %{
      participant_states:
        if(user_connected?, do: participant_states, else: Map.delete(participant_states, user_id)),
      user_connected?: user_connected?,
      host_disconnected?: host_user_id == user_id and not user_connected?,
      room_empty?: connection_count(connections) == 0
    }
  end
end
