defmodule Streamix.WatchParty do
  @moduledoc """
  Context for Watch Party — synchronized group viewing.
  """

  import Ecto.Query

  alias Streamix.Repo
  alias Streamix.WatchParty.{Room, Participant, Message, RoomServer}

  @topic_prefix "watch_party:room:"

  def topic(room_id), do: @topic_prefix <> to_string(room_id)

  # --- Room Management ---

  def create_room(user_id, attrs) do
    attrs = Map.put(attrs, :host_user_id, user_id)

    case %Room{} |> Room.create_changeset(attrs) |> Repo.insert() do
      {:ok, room} ->
        # Insert host as participant
        %Participant{}
        |> Participant.join_changeset(%{room_id: room.id, user_id: user_id, role: "host"})
        |> Repo.insert!()

        # Start the room server
        ensure_room_server(room)

        {:ok, room}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_room!(id), do: Repo.get!(Room, id)

  def get_room_by_invite(invite_code) do
    Repo.get_by(Room, invite_code: invite_code, status: "active")
  end

  def join_room(room_id, user_id) do
    room = get_room!(room_id)

    # Check participant limit
    active_count = active_participant_count(room_id)

    if active_count >= room.max_participants do
      {:error, :room_full}
    else
      result =
        %Participant{}
        |> Participant.join_changeset(%{room_id: room_id, user_id: user_id, role: "viewer"})
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: {:unsafe_fragment, "(room_id, user_id) WHERE left_at IS NULL"}
        )

      case result do
        {:ok, participant} ->
          RoomServer.join(room_id, user_id)
          broadcast(room_id, {:participant_joined, user_id})
          {:ok, participant}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def leave_room(room_id, user_id) do
    participant =
      Repo.one(
        from p in Participant,
          where: p.room_id == ^room_id and p.user_id == ^user_id and is_nil(p.left_at)
      )

    if participant do
      participant |> Participant.leave_changeset() |> Repo.update!()
      RoomServer.leave(room_id, user_id)
      broadcast(room_id, {:participant_left, user_id})
      :ok
    else
      :ok
    end
  end

  def end_room(room_id, user_id) do
    room = get_room!(room_id)

    if room.host_user_id == user_id do
      room |> Room.end_changeset() |> Repo.update!()

      # Mark all active participants as left
      from(p in Participant, where: p.room_id == ^room_id and is_nil(p.left_at))
      |> Repo.update_all(set: [left_at: DateTime.truncate(DateTime.utc_now(), :second)])

      broadcast(room_id, :room_ended)

      # Stop the server
      case RoomServer.whereis(room_id) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Streamix.WatchParty.RoomSupervisor, pid)
      end

      :ok
    else
      {:error, :not_host}
    end
  end

  # --- Playback ---

  def playback_action(room_id, user_id, action) do
    RoomServer.playback_action(room_id, user_id, action)
  end

  def send_sync_beacon(room_id, user_id, position, client_time) do
    RoomServer.sync_beacon(room_id, user_id, position, client_time)
  end

  def get_playback_state(room_id) do
    RoomServer.get_state(room_id)
  end

  # --- Messages ---

  def send_message(room_id, user_id, content, type \\ "text") do
    case %Message{}
         |> Message.changeset(%{room_id: room_id, user_id: user_id, content: content, type: type})
         |> Repo.insert() do
      {:ok, message} ->
        message = Repo.preload(message, :user)
        broadcast(room_id, {:new_message, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def list_messages(room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      where: m.room_id == ^room_id,
      order_by: [asc: m.inserted_at],
      limit: ^limit,
      preload: [:user]
    )
    |> Repo.all()
  end

  # --- Server Management ---

  def ensure_room_server(room) do
    case RoomServer.whereis(room.id) do
      nil ->
        DynamicSupervisor.start_child(
          Streamix.WatchParty.RoomSupervisor,
          {RoomServer,
           room_id: room.id,
           host_user_id: room.host_user_id,
           content_type: room.content_type,
           content_id: room.content_id}
        )

      pid ->
        {:ok, pid}
    end
  end

  # --- Helpers ---

  defp active_participant_count(room_id) do
    from(p in Participant, where: p.room_id == ^room_id and is_nil(p.left_at))
    |> Repo.aggregate(:count)
  end

  defp broadcast(room_id, message) do
    Phoenix.PubSub.broadcast(Streamix.PubSub, topic(room_id), message)
  end
end
