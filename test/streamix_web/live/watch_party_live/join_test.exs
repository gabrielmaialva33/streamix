defmodule StreamixWeb.WatchPartyLive.JoinTest do
  use StreamixWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.WatchParty.{Participant, Room}

  setup :register_and_log_in_user

  test "invite preflight never persists membership before the player connects", %{
    conn: conn,
    user: user
  } do
    provider = provider_fixture(user)
    movie = movie_fixture(provider, %{name: "Join Party Movie"})
    room = room_fixture(user, movie)

    {:ok, view, html} = live(conn, ~p"/party/#{room.invite_code}")

    assert html =~ "Join Party Movie"
    assert html =~ "0/10 participantes"
    refute active_participant?(room.id, user.id)

    render_click(view, "join", %{})

    assert_redirect(view, "/party/#{room.invite_code}/watch")
    refute active_participant?(room.id, user.id)
  end

  test "users without content entitlement are rejected before consuming a room slot", %{
    conn: conn,
    user: guest
  } do
    host = user_fixture()

    provider =
      provider_fixture(host, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie = movie_fixture(provider, %{name: "Premium Join Movie"})
    room = room_fixture(host, movie)

    assert {:error, {:redirect, %{to: to}}} =
             live(conn, ~p"/party/#{room.invite_code}")

    assert to =~ "/plans?upgrade=global_catalog"
    assert to =~ "return_to=%2Fparty%2F#{room.invite_code}"

    refute active_participant?(room.id, guest.id)
  end

  test "full room disables join button and blocks join event (AGY-03)", %{
    conn: conn,
    user: guest
  } do
    {:ok, guest} = Streamix.Accounts.make_admin_user(guest)
    host = user_fixture()

    provider =
      provider_fixture(host, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie = movie_fixture(provider, %{name: "Full Room Movie"})
    room = room_fixture(host, movie)

    # Fill room to maximum capacity (10 participants)
    for _i <- 1..10 do
      other_user = user_fixture()

      %Participant{}
      |> Participant.join_changeset(%{
        room_id: room.id,
        user_id: other_user.id,
        role: "viewer"
      })
      |> Repo.insert!()
    end

    {:ok, view, html} = live(conn, ~p"/party/#{room.invite_code}")

    assert html =~ "A sala está cheia agora"
    assert html =~ "disabled"
    assert html =~ ~s(aria-disabled="true")
    assert html =~ "cursor-not-allowed"

    # Even if client triggers join event, server flashes error instead of redirecting
    render_click(view, "join", %{})
    assert render(view) =~ "A sala atingiu a capacidade máxima"
    refute active_participant?(room.id, guest.id)
  end

  test "ended invites return to the party hub without exposing stale content", %{
    conn: conn,
    user: user
  } do
    provider = provider_fixture(user)
    movie = movie_fixture(provider, %{name: "Ended Party Movie"})

    room =
      user
      |> room_fixture(movie)
      |> Room.end_changeset("test_ended")
      |> Repo.update!()

    assert {:error, {:redirect, %{to: "/party"}}} =
             live(conn, ~p"/party/#{room.invite_code}")
  end

  defp room_fixture(user, movie) do
    %Room{}
    |> Room.create_changeset(%{
      host_user_id: user.id,
      catalog_item_id: movie.catalog_item_id,
      source_type: "movie",
      source_id: movie.id
    })
    |> Repo.insert!()
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
