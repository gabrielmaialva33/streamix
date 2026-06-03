defmodule Streamix.WatchParty do
  @moduledoc """
  Context for Watch Party — synchronized group viewing.
  """

  import Ecto.Query

  alias Streamix.Billing
  alias Streamix.Repo
  alias Streamix.WatchParty.{Message, Participant, Room, RoomServer}

  @topic_prefix "watch_party:room:"
  @room_content_preloads [catalog_item: [:movie, :series, :episode, :live_channel]]

  def topic(room_id), do: @topic_prefix <> to_string(room_id)

  # --- Room Management ---

  def create_room(user_id, attrs) do
    if Billing.entitled_user_id?(user_id, :watch_party) do
      do_create_room(user_id, attrs)
    else
      {:error, :watch_party_not_allowed}
    end
  end

  defp do_create_room(user_id, attrs) do
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

  def get_room_by_invite_with_content(invite_code) do
    invite_code
    |> get_room_by_invite()
    |> preload_room_content()
  end

  def preload_room_content(nil), do: nil
  def preload_room_content(%Room{} = room), do: Repo.preload(room, @room_content_preloads)

  def join_room(room_id, user_id, role \\ "viewer") do
    room = get_room!(room_id)

    cond do
      participant = active_participant(room_id, user_id) ->
        RoomServer.join(room_id, user_id)
        {:ok, participant}

      active_participant_count(room_id) >= room.max_participants ->
        {:error, :room_full}

      true ->
        %Participant{}
        |> Participant.join_changeset(%{room_id: room_id, user_id: user_id, role: role})
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: {:unsafe_fragment, "(room_id, user_id) WHERE left_at IS NULL"}
        )
        |> handle_join_result(room_id, user_id)
    end
  end

  defp handle_join_result({:ok, %Participant{id: nil}}, room_id, user_id) do
    case active_participant(room_id, user_id) do
      nil ->
        {:error, :room_join_conflict}

      participant ->
        RoomServer.join(room_id, user_id)
        {:ok, participant}
    end
  end

  defp handle_join_result({:ok, participant}, room_id, user_id) do
    RoomServer.join(room_id, user_id)
    broadcast(room_id, {:participant_joined, user_id})
    {:ok, participant}
  end

  defp handle_join_result({:error, changeset}, _room_id, _user_id), do: {:error, changeset}

  def leave_room(room_id, user_id) do
    participant =
      Repo.one(
        from(p in Participant,
          where: p.room_id == ^room_id and p.user_id == ^user_id and is_nil(p.left_at)
        )
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

  def send_sync_beacon(room_id, user_id, position, state, buffering, client_time) do
    RoomServer.sync_beacon(room_id, user_id, position, state, buffering, client_time)
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

    # Pull the most recent `limit` messages and flip to chronological order
    # for the chat stream. The previous `asc + limit` showed the *oldest*
    # 50, which on an active room meant the chat scrolled to a stale
    # window the moment a member opened it.
    from(m in Message,
      where: m.room_id == ^room_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [:user]
    )
    |> Repo.all()
    |> Enum.reverse()
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
           catalog_item_id: room.catalog_item_id}
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

  defp active_participant(room_id, user_id) do
    Repo.one(
      from(p in Participant,
        where: p.room_id == ^room_id and p.user_id == ^user_id and is_nil(p.left_at)
      )
    )
  end

  defp broadcast(room_id, message) do
    Phoenix.PubSub.broadcast(Streamix.PubSub, topic(room_id), message)
  end
end
