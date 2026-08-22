defmodule Streamix.WatchPartyTest do
  use Streamix.DataCase, async: false

  alias Streamix.{AccountsFixtures, Billing, IptvFixtures, WatchParty}
  alias Streamix.WatchParty.{Message, Participant, Room, RoomServer}

  test "cross-context ownership stays in scalar foreign keys and privacy labels are virtual" do
    assert Message.__schema__(:type, :user_id) == :id
    assert Participant.__schema__(:type, :user_id) == :id
    assert Room.__schema__(:type, :host_user_id) == :id
    assert Room.__schema__(:type, :catalog_item_id) == :id

    refute :user in Message.__schema__(:associations)
    refute :user in Participant.__schema__(:associations)
    refute :host_user in Room.__schema__(:associations)
    refute :catalog_item in Room.__schema__(:associations)

    assert :user_label in Message.__schema__(:virtual_fields)
    assert :catalog_item in Room.__schema__(:virtual_fields)
  end

  test "room content is resolved through the IPTV facade" do
    %{room: room, movie: movie} = room_fixture()

    loaded_room = WatchParty.get_room_by_invite_with_content(room.invite_code)

    assert loaded_room.catalog_item.id == movie.catalog_item_id
    assert Streamix.Iptv.catalog_item_content_name(loaded_room.catalog_item) == movie.name
  end

  test "room creation is idempotent for the same host and content" do
    %{user: user, movie: movie} = catalog_fixture()
    grant_watch_party!(user)

    attrs = %{
      catalog_item_id: movie.catalog_item_id,
      source_type: "movie",
      source_id: movie.id
    }

    assert {:ok, first_room} = WatchParty.create_room(user.id, attrs)
    assert {:ok, second_room} = WatchParty.create_room(user.id, attrs)
    assert first_room.id == second_room.id
    assert first_room.invite_code == second_room.invite_code

    assert Repo.aggregate(
             from(room in Room,
               where:
                 room.host_user_id == ^user.id and room.catalog_item_id == ^movie.catalog_item_id and
                   room.status == "active"
             ),
             :count
           ) == 1

    assert RoomServer.whereis(first_room.id)
    RoomServer.stop(first_room.id)
  end

  test "room creation rejects a source that does not match the canonical catalog item" do
    %{user: user, movie: movie} = catalog_fixture()
    grant_watch_party!(user)

    assert {:error, :content_not_available} =
             WatchParty.create_room(user.id, %{
               catalog_item_id: movie.catalog_item_id,
               source_type: "movie",
               source_id: movie.id + 999_999
             })

    refute Repo.exists?(
             from(room in Room,
               where: room.host_user_id == ^user.id and room.status == "active"
             )
           )
  end

  test "a persisted playback snapshot survives a room-server restart" do
    %{room: room, user: user} = room_fixture()

    assert {:ok, first_pid} = WatchParty.ensure_room_server(room)
    assert {:ok, _} = RoomServer.join(room.id, user.id, "host-tab")

    assert :ok =
             RoomServer.playback_action(room.id, user.id, "host-tab", %{
               "action" => "pause",
               "position" => 42.5
             })

    RoomServer.stop(room.id)
    refute Process.alive?(first_pid)

    recovered_room = Repo.get!(Room, room.id)
    assert {:ok, second_pid} = WatchParty.ensure_room_server(recovered_room)
    refute second_pid == first_pid

    assert {:ok, playback, host_user_id} = RoomServer.get_state(room.id)
    assert host_user_id == user.id
    assert playback.state == :paused
    assert_in_delta playback.position, 42.5, 0.01
    assert playback.version > 0

    RoomServer.stop(room.id)
  end

  test "an active participant rehydrates the same browser connection after a room crash" do
    %{user: user, movie: movie} = catalog_fixture()
    grant_watch_party!(user)

    assert {:ok, room} =
             WatchParty.create_room(user.id, %{
               catalog_item_id: movie.catalog_item_id,
               source_type: "movie",
               source_id: movie.id
             })

    assert {:ok, _participant} = WatchParty.join_room(room.id, user.id, "host-tab")
    first_pid = RoomServer.whereis(room.id)
    monitor = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, :killed}

    second_pid = await_restarted_room_server(room.id, first_pid)
    assert is_pid(second_pid)
    refute second_pid == first_pid

    assert :ok =
             WatchParty.playback_action(room.id, user.id, "host-tab", %{
               "action" => "play",
               "position" => 12.5
             })

    assert :sys.get_state(second_pid).connections[user.id] == MapSet.new(["host-tab"])
    RoomServer.stop(room.id)
  end

  test "periodic snapshots preserve the last real room activity timestamp" do
    %{user: user, movie: movie} = catalog_fixture()
    grant_watch_party!(user)

    assert {:ok, room} =
             WatchParty.create_room(user.id, %{
               catalog_item_id: movie.catalog_item_id,
               source_type: "movie",
               source_id: movie.id
             })

    assert {:ok, _participant} = WatchParty.join_room(room.id, user.id, "host-tab")
    room_server = RoomServer.whereis(room.id)
    activity_at = Repo.get!(Room, room.id).last_activity_at

    :sys.replace_state(room_server, fn state ->
      %{state | last_persisted_at: System.monotonic_time(:millisecond) - 20_000}
    end)

    send(room_server, :sync_broadcast)
    _barrier = :sys.get_state(room_server)

    assert Repo.get!(Room, room.id).last_activity_at == activity_at
    RoomServer.stop(room.id)
  end

  test "a browser process crash closes its durable participant lease" do
    %{user: user, movie: movie} = catalog_fixture()
    grant_watch_party!(user)

    assert {:ok, room} =
             WatchParty.create_room(user.id, %{
               catalog_item_id: movie.catalog_item_id,
               source_type: "movie",
               source_id: movie.id
             })

    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room.id))
    test_pid = self()

    browser_pid =
      spawn(fn ->
        send(test_pid, {:joined, WatchParty.join_room(room.id, user.id, "host-tab")})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:joined, {:ok, _participant}}
    Process.exit(browser_pid, :kill)
    assert_receive {:participant_left, user_id}
    assert user_id == user.id

    refute Repo.exists?(
             from(participant in Participant,
               where:
                 participant.room_id == ^room.id and participant.user_id == ^user.id and
                   is_nil(participant.left_at)
             )
           )

    RoomServer.stop(room.id)
  end

  test "messages require active membership, trim content, and never expose account email" do
    %{room: room, user: user} = room_fixture()
    participant_fixture(room, user)

    assert {:ok, %Message{content: "e aí", user_label: label}} =
             WatchParty.send_message(room.id, user.id, "  e aí  ")

    assert label == WatchParty.participant_label(room.id, user.id)
    refute label =~ "@"

    assert [%Message{content: "e aí", user_label: ^label}] = WatchParty.list_messages(room.id)

    outsider = AccountsFixtures.user_fixture()
    assert {:error, :not_participant} = WatchParty.send_message(room.id, outsider.id, "oi")
  end

  test "reactions are whitelisted ephemeral room events rather than retained chat rows" do
    %{room: room, user: user} = room_fixture()
    participant_fixture(room, user)
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room.id))

    assert :ok = WatchParty.send_reaction(room.id, user.id, "🔥")

    assert_receive {:reaction,
                    %{
                      emoji: "🔥",
                      user_id: user_id,
                      user_label: user_label
                    }}

    assert user_id == user.id
    assert user_label == WatchParty.participant_label(room.id, user.id)

    assert Repo.aggregate(from(message in Message, where: message.room_id == ^room.id), :count) ==
             0

    assert {:error, :invalid_reaction} = WatchParty.send_reaction(room.id, user.id, "<script>")
  end

  test "active room listing includes rooms hosted by or joined by the user" do
    %{room: hosted_room, user: host} = room_fixture()
    guest = AccountsFixtures.user_fixture()
    participant_fixture(hosted_room, guest)

    hosted_ids = host.id |> WatchParty.list_active_rooms_for_user() |> Enum.map(& &1.id)
    joined_ids = guest.id |> WatchParty.list_active_rooms_for_user() |> Enum.map(& &1.id)

    assert hosted_room.id in hosted_ids
    assert hosted_room.id in joined_ids
  end

  test "inactive rooms are ended and old ended rooms can be purged" do
    %{room: room} = room_fixture()
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

    room
    |> Ecto.Changeset.change(last_activity_at: DateTime.add(cutoff, -1, :second))
    |> Repo.update!()

    assert WatchParty.expire_inactive_rooms(cutoff) == 1

    ended_room = Repo.get!(Room, room.id)
    assert ended_room.status == "ended"
    assert ended_room.ended_reason == "inactive_cleanup"

    ended_room
    |> Ecto.Changeset.change(
      ended_at: cutoff |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert WatchParty.purge_ended_rooms(cutoff) == 1
    refute Repo.get(Room, room.id)
  end

  defp room_fixture do
    %{user: user, movie: movie} = catalog_fixture()

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: user.id,
        catalog_item_id: movie.catalog_item_id,
        source_type: "movie",
        source_id: movie.id
      })
      |> Repo.insert!()

    %{room: room, user: user, movie: movie}
  end

  defp catalog_fixture do
    user = AccountsFixtures.user_fixture()
    provider = IptvFixtures.provider_fixture(user)
    movie = IptvFixtures.movie_fixture(provider, %{name: "Party Movie"})
    %{user: user, provider: provider, movie: movie}
  end

  defp participant_fixture(room, user, role \\ "viewer") do
    %Participant{}
    |> Participant.join_changeset(%{room_id: room.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp await_restarted_room_server(room_id, previous_pid, attempts \\ 50)

  defp await_restarted_room_server(_room_id, _previous_pid, 0), do: nil

  defp await_restarted_room_server(room_id, previous_pid, attempts) do
    case RoomServer.whereis(room_id) do
      pid when is_pid(pid) and pid != previous_pid ->
        pid

      _other ->
        receive do
        after
          10 -> await_restarted_room_server(room_id, previous_pid, attempts - 1)
        end
    end
  end

  defp grant_watch_party!(user) do
    unique = System.unique_integer([:positive])

    plan =
      Billing.ensure_plan!(%{
        name: "Watch Party Test #{unique}",
        slug: "watch-party-test-#{unique}",
        description: "Watch Party test plan",
        price_cents: 0,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: false,
        features: %{watch_party: true}
      })

    Billing.ensure_manual_subscription!(user, plan, %{
      status: "active",
      starts_at: DateTime.utc_now(:second),
      external_reference: "watch-party-test:#{unique}"
    })
  end
end
