defmodule StreamixWeb.WatchPartyLive.IndexTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.WatchParty.Room

  setup :register_and_log_in_user

  test "lists active rooms so the user can resume instead of creating duplicates", %{
    conn: conn,
    user: user
  } do
    provider = provider_fixture(user)
    movie = movie_fixture(provider, %{name: "Resumable Party Movie"})

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: user.id,
        catalog_item_id: movie.catalog_item_id,
        source_type: "movie",
        source_id: movie.id
      })
      |> Repo.insert!()

    {:ok, view, html} = live(conn, ~p"/party")

    assert html =~ "Suas salas ativas"
    assert html =~ "Resumable Party Movie"
    assert html =~ String.upcase(room.invite_code)
    assert has_element?(view, "a[href='/party/#{room.invite_code}/watch']")
  end

  test "does not render the active-room section when the user has none", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/party")

    refute has_element?(view, "#active-parties-title")
  end
end
