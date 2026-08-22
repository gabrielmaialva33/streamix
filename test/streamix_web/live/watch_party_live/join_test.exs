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

    assert {:error, {:redirect, %{to: "/plans?upgrade=global_catalog"}}} =
             live(conn, ~p"/party/#{room.invite_code}")

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
