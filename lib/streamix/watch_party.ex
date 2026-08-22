defmodule Streamix.WatchParty do
  @moduledoc """
  Context for synchronized group viewing.

  The database owns durable room membership and playback snapshots, while a
  per-room `RoomServer` owns the live timeline. Browser connections are tracked
  independently so closing one tab cannot evict the same user from another.
  """

  import Ecto.Query, warn: false

  alias Streamix.{Access, Accounts, Billing, Iptv, Repo, Torrent}
  alias Streamix.WatchParty.{Message, Participant, Room, RoomServer}

  @topic_prefix "watch_party:room:"
  @allowed_reactions ~w(👍 ❤️ 😂 😮 😢 🔥)
  @message_limit 200

  def topic(room_id), do: @topic_prefix <> to_string(room_id)
  def allowed_reactions, do: @allowed_reactions

  # --- Room Management ---

  def create_room(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    if Billing.entitled_user_id?(user_id, :watch_party) do
      case authorize_content_ref(user_id, attrs) do
        :ok -> do_create_room(user_id, attrs)
        {:error, _reason} = error -> error
      end
    else
      {:error, :watch_party_not_allowed}
    end
  end

  defp do_create_room(user_id, %{catalog_item_id: catalog_item_id} = attrs)
       when is_integer(catalog_item_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [
        create_advisory_lock_key(user_id, catalog_item_id)
      ])

      create_or_reuse_room(user_id, catalog_item_id, attrs)
    end)
    |> finish_room_creation()
  end

  defp do_create_room(_user_id, _attrs), do: {:error, :invalid_catalog_item}

  def get_room!(id), do: Repo.get!(Room, id)
  def get_room(id), do: Repo.get(Room, id)

  def get_room_by_invite(invite_code) when is_binary(invite_code) do
    Repo.get_by(Room, invite_code: String.downcase(invite_code), status: "active")
  end

  def get_room_by_invite(_invite_code), do: nil

  def get_room_by_invite_with_content(invite_code) do
    invite_code
    |> get_room_by_invite()
    |> preload_room_content()
  end

  def preload_room_content(nil), do: nil

  def preload_room_content(%Room{} = room) do
    %{room | catalog_item: Iptv.get_catalog_item_with_content(room.catalog_item_id)}
  end

  def list_active_rooms_for_user(user_id, opts \\ []) when is_integer(user_id) do
    limit = opts |> Keyword.get(:limit, 6) |> min(20) |> max(1)

    Room
    |> join(:left, [room], participant in Participant,
      on:
        participant.room_id == room.id and participant.user_id == ^user_id and
          is_nil(participant.left_at)
    )
    |> where(
      [room, participant],
      room.status == "active" and
        (room.host_user_id == ^user_id or not is_nil(participant.id))
    )
    |> order_by([room], desc: room.last_activity_at, desc: room.id)
    |> limit(^limit)
    |> distinct(true)
    |> Repo.all()
    |> Enum.map(&preload_room_content/1)
  end

  def room_capacity(room_id, user_id \\ nil) when is_integer(room_id) do
    case Repo.get(Room, room_id) do
      %Room{} = room ->
        current = active_participant_count(room_id)
        returning? = is_integer(user_id) and not is_nil(active_participant(room_id, user_id))

        full? =
          cond do
            returning? -> false
            user_id == room.host_user_id -> false
            true -> active_viewer_count(room_id, room.host_user_id) >= room.max_participants - 1
          end

        %{current: current, maximum: room.max_participants, full?: full?}

      nil ->
        %{current: 0, maximum: 0, full?: true}
    end
  end

  @doc "Returns `:ok` only when the user can independently play the room content."
  def authorize_room_user(%Room{} = room, user_id) when is_integer(user_id) do
    room = preload_room_content(room)
    user = Accounts.get_user(user_id, preload_role: true)

    with %{} = catalog_item <- room.catalog_item,
         %{} = content <- Iptv.catalog_item_content(catalog_item),
         {:ok, provider} <- playable_provider(catalog_item.content_type, content.id, user_id),
         %{} = user <- user,
         true <- Access.plays_global_content?(user, provider) do
      :ok
    else
      false -> {:error, :content_not_entitled}
      _ -> {:error, :content_not_available}
    end
  end

  def authorize_room_user(_room, _user_id), do: {:error, :content_not_available}

  def join_room(room_id, user_id, connection_id)
      when is_integer(room_id) and is_integer(user_id) do
    with %Room{status: "active"} = room <- get_room(room_id),
         :ok <- authorize_room_user(room, user_id),
         {:ok, _pid} <- ensure_room_server(room),
         {:ok, {participant, inserted?}} <- insert_participant(room, user_id) do
      finish_room_join(room_id, user_id, connection_id, participant, inserted?)
    else
      nil -> {:error, :room_not_found}
      %Room{} -> {:error, :room_ended}
      {:error, reason} -> {:error, reason}
    end
  end

  def leave_room(room_id, user_id, connection_id)
      when is_integer(room_id) and is_integer(user_id) do
    server_result =
      case RoomServer.whereis(room_id) do
        nil -> {:ok, %{user_connected?: false, room_empty?: true}}
        _pid -> safe_server_call(fn -> RoomServer.leave(room_id, user_id, connection_id) end)
      end

    case server_result do
      {:ok, %{user_connected?: true}} ->
        :ok

      {:ok, %{user_connected?: false}} ->
        mark_participant_left(room_id, user_id)
        broadcast(room_id, {:participant_left, user_id})
        :ok

      {:error, _reason} ->
        mark_participant_left(room_id, user_id)
        :ok
    end
  end

  def end_room(room_id, user_id, connection_id) do
    result =
      case RoomServer.whereis(room_id) do
        nil -> end_room_without_server(room_id, user_id, "host_ended")
        _pid -> safe_server_call(fn -> RoomServer.end_room(room_id, user_id, connection_id) end)
      end

    if result == :ok do
      mark_all_participants_left(room_id)
    end

    result
  end

  def change_content(
        room_id,
        user_id,
        connection_id,
        %{catalog_item_id: catalog_item_id, source_type: source_type, source_id: source_id} =
          content_ref
      )
      when is_integer(catalog_item_id) and catalog_item_id > 0 and is_binary(source_type) and
             is_integer(source_id) and source_id > 0 do
    with :ok <- authorize_content_ref(user_id, content_ref) do
      RoomServer.change_content(room_id, user_id, connection_id, content_ref)
    end
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  def change_content(_room_id, _user_id, _connection_id, _content_ref),
    do: {:error, :invalid_content_ref}

  # --- Playback ---

  def playback_action(room_id, user_id, connection_id, action) do
    RoomServer.playback_action(room_id, user_id, connection_id, action)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  def send_sync_beacon(
        room_id,
        user_id,
        connection_id,
        position,
        participant_state,
        buffering,
        client_time
      ) do
    RoomServer.sync_beacon(
      room_id,
      user_id,
      connection_id,
      position,
      participant_state,
      buffering,
      client_time
    )
  catch
    :exit, _reason -> :ok
  end

  def get_playback_state(room_id) do
    RoomServer.get_state(room_id)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  # --- Messages and reactions ---

  def send_message(room_id, user_id, content) do
    with :ok <- active_room_member?(room_id, user_id),
         {:ok, message} <-
           %Message{}
           |> Message.changeset(%{
             room_id: room_id,
             user_id: user_id,
             content: content,
             type: "text"
           })
           |> Repo.insert() do
      message = attach_message_user_label(message)
      touch_room(room_id)
      broadcast(room_id, {:new_message, message})
      {:ok, message}
    end
  end

  def send_reaction(room_id, user_id, emoji) when emoji in @allowed_reactions do
    with :ok <- active_room_member?(room_id, user_id) do
      touch_room(room_id)

      broadcast(room_id, {
        :reaction,
        %{emoji: emoji, user_id: user_id, user_label: participant_label(room_id, user_id)}
      })

      :ok
    end
  end

  def send_reaction(_room_id, _user_id, _emoji), do: {:error, :invalid_reaction}

  def list_messages(room_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(@message_limit) |> max(1)

    from(message in Message,
      where: message.room_id == ^room_id and message.type != "reaction",
      order_by: [desc: message.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
    |> attach_message_user_labels()
  end

  def participant_label(room_id, user_id) do
    suffix =
      :crypto.hash(:sha256, "#{room_id}:#{user_id}")
      |> Base.encode16(case: :upper)
      |> binary_part(0, 4)

    "Pessoa #{suffix}"
  end

  # --- Cleanup and server management ---

  @doc "Ends inactive rooms and releases their participants."
  def expire_inactive_rooms(cutoff) do
    rooms =
      Repo.transaction(fn ->
        rooms =
          from(room in Room,
            where: room.status == "active" and room.last_activity_at < ^cutoff,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> Repo.all()

        Enum.each(rooms, fn room ->
          room
          |> Room.end_changeset("inactive_cleanup")
          |> Repo.update!()

          mark_all_participants_left(room.id)
        end)

        rooms
      end)
      |> case do
        {:ok, rooms} ->
          rooms

        {:error, reason} ->
          raise "failed to expire inactive Watch Party rooms: #{inspect(reason)}"
      end

    Enum.each(rooms, fn room ->
      broadcast(room.id, {:room_ended, "inactive_cleanup"})
      RoomServer.stop(room.id)
    end)

    length(rooms)
  end

  def purge_ended_rooms(cutoff) do
    {count, _} =
      from(room in Room,
        where: room.status == "ended" and room.ended_at < ^cutoff
      )
      |> Repo.delete_all()

    count
  end

  @doc "Deletes rooms whose content belongs to the given catalog items."
  @spec delete_rooms_by_catalog_item_ids([integer()], keyword()) :: non_neg_integer()
  def delete_rooms_by_catalog_item_ids(catalog_item_ids, opts \\ [])
      when is_list(catalog_item_ids) and is_list(opts) do
    active_room_ids =
      from(room in Room,
        where: room.catalog_item_id in ^catalog_item_ids and room.status == "active",
        select: room.id
      )
      |> Repo.all(opts)

    {count, _rooms} =
      Room
      |> where([room], room.catalog_item_id in ^catalog_item_ids)
      |> Repo.delete_all(opts)

    Enum.each(active_room_ids, fn room_id ->
      broadcast(room_id, {:room_ended, "content_removed"})
      RoomServer.stop(room_id)
    end)

    count
  end

  def ensure_room_server(%Room{status: "active"} = room) do
    case RoomServer.whereis(room.id) do
      nil ->
        case DynamicSupervisor.start_child(
               Streamix.WatchParty.RoomSupervisor,
               {RoomServer,
                room_id: room.id,
                host_user_id: room.host_user_id,
                catalog_item_id: room.catalog_item_id,
                source_type: room.source_type,
                source_id: room.source_id,
                persist?: true}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, :already_present} -> room_server_pid(room.id)
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  def ensure_room_server(%Room{}), do: {:error, :room_ended}

  # --- Private helpers ---

  defp create_or_reuse_room(user_id, catalog_item_id, attrs) do
    case active_host_room(user_id, catalog_item_id) do
      %Room{} = room -> room
      nil -> insert_room(user_id, attrs)
    end
  end

  defp insert_room(user_id, attrs) do
    attrs = Map.put(attrs, :host_user_id, user_id)

    case %Room{} |> Room.create_changeset(attrs) |> Repo.insert() do
      {:ok, room} -> room
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp finish_room_creation({:ok, %Room{} = room}) do
    case ensure_room_server(room) do
      {:ok, _pid} ->
        {:ok, room}

      {:error, reason} ->
        end_room_record(room, "server_start_failed")
        {:error, reason}
    end
  end

  defp finish_room_creation({:error, reason}), do: {:error, reason}

  defp finish_room_join(room_id, user_id, connection_id, participant, inserted?) do
    case room_server_join(room_id, user_id, connection_id) do
      {:ok, _playback} ->
        if inserted?, do: broadcast(room_id, {:participant_joined, user_id})
        {:ok, participant}

      {:error, reason} ->
        if inserted?, do: mark_participant_left(room_id, user_id)
        {:error, reason}
    end
  end

  defp insert_participant(room, user_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [participant_advisory_lock_key(room.id)])

      Room
      |> Repo.get(room.id)
      |> insert_participant_locked(room.id, user_id)
    end)
  end

  defp insert_participant_locked(%Room{status: "active"} = room, room_id, user_id) do
    case active_participant(room_id, user_id) do
      %Participant{} = participant -> {participant, false}
      nil -> insert_new_participant(room, room_id, user_id)
    end
  end

  defp insert_participant_locked(_room, _room_id, _user_id), do: Repo.rollback(:room_ended)

  defp insert_new_participant(room, room_id, user_id) do
    cond do
      room.host_user_id == user_id ->
        insert_participant_record(room_id, user_id, "host")

      active_viewer_count(room_id, room.host_user_id) >= room.max_participants - 1 ->
        Repo.rollback(:room_full)

      true ->
        insert_participant_record(room_id, user_id, "viewer")
    end
  end

  defp insert_participant_record(room_id, user_id, role) do
    %Participant{}
    |> Participant.join_changeset(%{room_id: room_id, user_id: user_id, role: role})
    |> Repo.insert()
    |> case do
      {:ok, participant} -> {participant, true}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp room_server_join(room_id, user_id, connection_id) do
    safe_server_call(fn -> RoomServer.join(room_id, user_id, connection_id) end)
  end

  defp safe_server_call(callback) do
    callback.()
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  defp active_room_member?(room_id, user_id) do
    case Repo.one(
           from(participant in Participant,
             join: room in Room,
             on: room.id == participant.room_id,
             where:
               participant.room_id == ^room_id and participant.user_id == ^user_id and
                 is_nil(participant.left_at) and room.status == "active",
             select: true,
             limit: 1
           )
         ) do
      true -> :ok
      _ -> {:error, :not_participant}
    end
  end

  defp active_participant_count(room_id) do
    from(participant in Participant,
      where: participant.room_id == ^room_id and is_nil(participant.left_at)
    )
    |> Repo.aggregate(:count)
  end

  defp active_viewer_count(room_id, host_user_id) do
    from(participant in Participant,
      where:
        participant.room_id == ^room_id and participant.user_id != ^host_user_id and
          is_nil(participant.left_at)
    )
    |> Repo.aggregate(:count)
  end

  defp active_participant(room_id, user_id) do
    Repo.one(
      from(participant in Participant,
        where:
          participant.room_id == ^room_id and participant.user_id == ^user_id and
            is_nil(participant.left_at)
      )
    )
  end

  defp mark_participant_left(room_id, user_id) do
    now = DateTime.utc_now(:second)

    from(participant in Participant,
      where:
        participant.room_id == ^room_id and participant.user_id == ^user_id and
          is_nil(participant.left_at)
    )
    |> Repo.update_all(set: [left_at: now, updated_at: now])

    :ok
  end

  defp mark_all_participants_left(room_id) do
    now = DateTime.utc_now(:second)

    from(participant in Participant,
      where: participant.room_id == ^room_id and is_nil(participant.left_at)
    )
    |> Repo.update_all(set: [left_at: now, updated_at: now])

    :ok
  end

  defp end_room_without_server(room_id, user_id, reason) do
    case Repo.get(Room, room_id) do
      %Room{host_user_id: ^user_id, status: "active"} = room ->
        end_room_record(room, reason)
        broadcast(room_id, {:room_ended, reason})
        :ok

      %Room{host_user_id: ^user_id} ->
        :ok

      %Room{} ->
        {:error, :not_host}

      nil ->
        {:error, :room_not_found}
    end
  end

  defp end_room_record(room, reason) do
    room
    |> Room.end_changeset(reason)
    |> Repo.update()
  end

  defp touch_room(room_id) do
    now = DateTime.utc_now()

    from(room in Room, where: room.id == ^room_id and room.status == "active")
    |> Repo.update_all(set: [last_activity_at: now, updated_at: DateTime.utc_now(:second)])

    :ok
  end

  defp playable_provider("live_channel", content_id, user_id) do
    case Iptv.get_playable_channel(user_id, content_id) do
      %{provider: provider} -> {:ok, provider}
      _ -> {:error, :content_not_available}
    end
  end

  defp playable_provider("movie", content_id, user_id) do
    case Iptv.get_playable_movie(user_id, content_id) do
      %{provider: provider} -> {:ok, provider}
      _ -> {:error, :content_not_available}
    end
  end

  defp playable_provider("episode", content_id, user_id) do
    case Iptv.get_playable_episode(user_id, content_id) do
      %{season: %{series: %{provider: provider}}} -> {:ok, provider}
      _ -> {:error, :content_not_available}
    end
  end

  defp playable_provider(_content_type, _content_id, _user_id),
    do: {:error, :content_not_available}

  defp authorize_content_ref(
         user_id,
         %{catalog_item_id: catalog_item_id, source_type: source_type, source_id: source_id}
       ) do
    user = Accounts.get_user(user_id, preload_role: true)

    with %{} = catalog_item <- Iptv.get_catalog_item_with_content(catalog_item_id),
         %{} = content <- Iptv.catalog_item_content(catalog_item),
         :ok <- validate_source_match(source_type, source_id, catalog_item, content),
         {:ok, provider} <- playable_provider(catalog_item.content_type, content.id, user_id),
         %{} = user <- user,
         true <- Access.plays_global_content?(user, provider) do
      :ok
    else
      false -> {:error, :content_not_entitled}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :content_not_available}
    end
  end

  defp authorize_content_ref(_user_id, _content_ref), do: {:error, :invalid_content_ref}

  defp source_matches_catalog?(
         "live_channel",
         source_id,
         %{content_type: "live_channel"},
         content
       ),
       do: content.id == source_id

  defp source_matches_catalog?("movie", source_id, %{content_type: "movie"}, content),
    do: content.id == source_id

  defp source_matches_catalog?("episode", source_id, %{content_type: "episode"}, content),
    do: content.id == source_id

  defp source_matches_catalog?("gindex", source_id, %{content_type: "movie"}, content),
    do: content.id == source_id and present_path?(Map.get(content, :gindex_path))

  defp source_matches_catalog?(
         "gindex_episode",
         source_id,
         %{content_type: "episode"},
         content
       ),
       do: content.id == source_id and present_path?(Map.get(content, :gindex_path))

  defp source_matches_catalog?("torrent", source_id, %{id: catalog_item_id}, _content) do
    case Torrent.get_stream_for_playback(source_id) do
      {:ok, _stream, %{catalog_item_id: ^catalog_item_id}, _provider} -> true
      _ -> false
    end
  end

  defp source_matches_catalog?(_source_type, _source_id, _catalog_item, _content), do: false

  defp validate_source_match(source_type, source_id, catalog_item, content) do
    if source_matches_catalog?(source_type, source_id, catalog_item, content) do
      :ok
    else
      {:error, :content_not_available}
    end
  end

  defp present_path?(path), do: is_binary(path) and path != ""

  defp active_host_room(user_id, catalog_item_id) do
    Repo.one(
      from(room in Room,
        where:
          room.host_user_id == ^user_id and room.catalog_item_id == ^catalog_item_id and
            room.status == "active",
        order_by: [desc: room.id],
        limit: 1
      )
    )
  end

  defp attach_message_user_label(%Message{} = message) do
    %{message | user_label: participant_label(message.room_id, message.user_id)}
  end

  defp attach_message_user_labels(messages), do: Enum.map(messages, &attach_message_user_label/1)

  defp participant_advisory_lock_key(room_id) do
    Bitwise.bor(Bitwise.bsl(0xC0FFEE, 32), room_id)
  end

  defp create_advisory_lock_key(user_id, catalog_item_id) do
    suffix = :erlang.phash2({user_id, catalog_item_id}, 4_294_967_295)
    Bitwise.bor(Bitwise.bsl(0xC0FFEF, 32), suffix)
  end

  defp room_server_pid(room_id) do
    case RoomServer.whereis(room_id) do
      nil -> {:error, :room_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp broadcast(room_id, message) do
    Phoenix.PubSub.broadcast(Streamix.PubSub, topic(room_id), message)
  end
end
