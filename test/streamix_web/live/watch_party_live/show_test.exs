defmodule StreamixWeb.WatchPartyLive.ShowTest do
  use StreamixWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.{Billing, Repo, WatchParty}
  alias Streamix.Billing.PlaybackSession
  alias Streamix.WatchParty.{Participant, Room, RoomServer}

  setup :register_and_log_in_user

  setup %{user: user} do
    grant_global_catalog!(user)

    provider =
      provider_fixture(user, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie = movie_fixture(provider, %{name: "Party Movie", duration_secs: 7_200})

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: user.id,
        catalog_item_id: movie.catalog_item_id,
        source_type: "movie",
        source_id: movie.id
      })
      |> Repo.insert!()

    on_exit(fn -> RoomServer.stop(room.id) end)

    %{room: room, movie: movie, provider: provider}
  end

  test "the static HTTP pass does not consume participant or playback slots", %{
    conn: conn,
    room: room,
    user: user
  } do
    conn = get(conn, ~p"/party/#{room.invite_code}/watch")
    html = html_response(conn, 200)

    assert html =~ "watch-party-sync"
    assert html =~ "watch-party-player-reserving"
    refute html =~ "data-stream-url="
    refute html =~ "data-next-episode="
    refute active_participant?(room.id, user.id)
    assert Billing.active_playback_count(user) == 0
    assert RoomServer.whereis(room.id) == nil
  end

  test "the connected player joins once and reserves one playback slot", %{
    conn: conn,
    room: room,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    assert has_element?(view, "#watch-party-sync[phx-hook='WatchPartySync'][data-is-host='true']")
    assert has_element?(view, "#video-player-container[data-stream-url]")
    refute has_element?(view, "#watch-party-player-reserving")

    assert active_participant?(room.id, user.id)
    assert Billing.active_playback_count(user) == 1

    pid = RoomServer.whereis(room.id)
    assert is_pid(pid)
    assert MapSet.size(:sys.get_state(pid).connections[user.id]) == 1
  end

  test "stable sync state stays out of the video and only exceptional states are shown", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    refute has_element?(view, "#watch-party-sync-status")

    render_hook(view, "wp_sync_status", %{"status" => "buffering", "drift_ms" => nil})
    assert has_element?(view, "#watch-party-sync-status", "Aguardando o buffer")

    render_hook(view, "wp_sync_status", %{"status" => "synced", "drift_ms" => 0})
    refute has_element?(view, "#watch-party-sync-status")
  end

  test "closing one tab preserves membership and playback for another tab", %{
    conn: conn,
    room: room,
    user: user
  } do
    {:ok, first_view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")
    {:ok, second_view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    pid = RoomServer.whereis(room.id)
    assert MapSet.size(:sys.get_state(pid).connections[user.id]) == 2
    assert Billing.active_playback_count(user) == 2

    render_hook(first_view, "wp_leave", %{})
    assert_redirect(first_view, "/")

    assert MapSet.size(:sys.get_state(pid).connections[user.id]) == 1
    assert active_participant?(room.id, user.id)
    assert Billing.active_playback_count(user) == 1
    assert Process.alive?(second_view.pid)
  end

  test "malformed client beacons are ignored without mutating or crashing the room", %{
    conn: conn,
    room: room,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")
    pid = RoomServer.whereis(room.id)

    render_hook(view, "wp_sync_beacon", %{
      "position" => "not-a-number",
      "state" => "invalid",
      "buffering" => "true",
      "client_time" => -1
    })

    state = :sys.get_state(pid)
    assert Process.alive?(view.pid)
    assert Process.alive?(pid)
    refute Map.has_key?(state.participant_states, user.id)
  end

  test "the VideoPlayer buffering event updates the host-authoritative room state", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")
    Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room.id))

    render_hook(view, "buffering", %{"buffering" => true})

    assert_receive {:sync_command, %{host_buffering: true}}
    assert {:ok, %{host_buffering: true}, _host_user_id} = RoomServer.get_state(room.id)
    assert Process.alive?(view.pid)
  end

  test "urgent buffering transitions bypass the normal beacon cadence once", %{
    conn: conn,
    room: room,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")
    pid = RoomServer.whereis(room.id)

    render_hook(view, "wp_sync_beacon", %{
      "position" => 12.0,
      "state" => "playing",
      "buffering" => false,
      "client_time" => 1,
      "urgent" => false
    })

    render_hook(view, "wp_sync_beacon", %{
      "position" => 12.0,
      "state" => "playing",
      "buffering" => true,
      "client_time" => 2,
      "urgent" => true
    })

    state = :sys.get_state(pid)
    assert state.participant_states[user.id].buffering == true
    assert state.playback.host_buffering == true
  end

  test "targeted resync reaches only the intended user's compatible client event", %{
    conn: host_conn,
    room: room
  } do
    guest = admin_user_fixture()
    guest_conn = build_conn() |> log_in_user(guest)

    {:ok, host_view, _html} = live(host_conn, ~p"/party/#{room.invite_code}/watch")
    {:ok, guest_view, _html} = live(guest_conn, ~p"/party/#{room.invite_code}/watch")

    command = %{
      type: "sync",
      target_user_id: guest.id,
      state: "playing",
      position: 44.0,
      host_buffering: false,
      sequence: 7,
      server_time: System.system_time(:millisecond)
    }

    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      WatchParty.topic(room.id),
      {:resync_user, command}
    )

    assert_push_event(guest_view, "wp_sync_command", ^command)
    assert Process.alive?(guest_view.pid)
    assert Process.alive?(host_view.pid)
  end

  test "subtitle controls shared with the normal player remain functional", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    render_hook(view, "adjust_subtitle_offset", %{"delta" => "500"})
    assert_push_event(view, "subtitle_offset_changed", %{offset_ms: 500})

    render_hook(view, "reset_subtitle_offset", %{})
    assert_push_event(view, "subtitle_offset_changed", %{offset_ms: 0})
    assert Process.alive?(view.pid)
  end

  test "player events are handled defensively without remounting playback", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    events = [
      {"player_lifecycle",
       %{"stage" => "player_cleanup", "engine" => "native", "session_id" => 0}},
      {"ios_pwa_player_event", %{"event" => "visibilitychange", "content_id" => "1"}},
      {"progress_update", %{"current_time" => 12.0, "duration" => 120.0}},
      {"player_initializing", %{}},
      {"player_error", %{"message" => "boom"}},
      {"buffering", %{"buffering" => true}},
      {"duration_available", %{"duration" => 120.0}},
      {"update_watch_time", %{"duration" => 30}},
      {"future_player_event", %{"safe" => true}}
    ]

    for {event, payload} <- events do
      assert render_hook(view, event, payload)
      assert Process.alive?(view.pid), "LiveView died handling #{event}"
    end
  end

  test "room content changes navigate every participant inside the party route", %{
    conn: conn,
    room: room
  } do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      WatchParty.topic(room.id),
      {:content_changed, %{version: 12}}
    )

    assert_redirect(view, "/party/#{room.invite_code}/watch?v=12")
  end

  test "leaving releases the playback session immediately", %{conn: conn, room: room, user: user} do
    {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")
    assert Billing.active_playback_count(user) == 1

    render_hook(view, "wp_leave", %{})
    assert_redirect(view, "/")

    assert Billing.active_playback_count(user) == 0

    user_id = user.id

    refute Repo.exists?(
             from(session in PlaybackSession,
               where: session.user_id == ^user_id and session.status == "active"
             )
           )
  end

  defp grant_global_catalog!(user) do
    unique = System.unique_integer([:positive])

    plan =
      Billing.ensure_plan!(%{
        name: "Global Party Test #{unique}",
        slug: "global-party-test-#{unique}",
        description: "Global Watch Party test access",
        price_cents: 0,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true,
        features: %{global_catalog: true}
      })

    Billing.ensure_manual_subscription!(user, plan, %{
      status: "active",
      starts_at: DateTime.utc_now(:second),
      external_reference: "global-party-test:#{unique}"
    })
  end

  defp active_participant?(room_id, user_id) do
    Repo.exists?(
      from(participant in Participant,
        where:
          participant.room_id == ^room_id and participant.user_id == ^user_id and
            is_nil(participant.left_at)
      )
    )
  end
end
