defmodule StreamixWeb.StationsLiveTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Streamix.Programming.Station
  alias Streamix.Repo
  alias StreamixWeb.{Presence, StationPaths}

  setup :register_and_log_in_user

  setup do
    station =
      %Station{}
      |> Station.changeset(%{
        slug: "terror-anos-80",
        name: "Terror Anos 80",
        query: "terror anos 80",
        description: "Slashers."
      })
      |> Repo.insert!()
      |> Station.program_changeset(
        [
          %{
            "movie_id" => 11,
            "duration" => 3_600,
            "title" => "Pânico na Floresta",
            "year" => 1983
          },
          %{"movie_id" => 12, "duration" => 3_600, "title" => "A Noite do Terror"}
        ],
        DateTime.add(DateTime.utc_now(), -900, :second)
      )
      |> Repo.update!()

    %{station: station}
  end

  test "lists what each station plays now and next", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/canais")

    assert has_element?(view, "#stations-terror-anos-80", "Terror Anos 80")
    assert has_element?(view, "#stations-terror-anos-80", "Pânico na Floresta (1983)")
    assert has_element?(view, "#stations-terror-anos-80", "A seguir: A Noite do Terror")
    assert has_element?(view, "#stations-terror-anos-80 [style='width: 25%']")
    refute has_element?(view, "#stations-empty")
  end

  test "updates the card when the station moves on and counts viewers", %{
    conn: conn,
    station: station
  } do
    {:ok, view, _html} = live(conn, ~p"/canais")

    station
    |> Station.program_changeset(
      [%{"movie_id" => 13, "duration" => 3_600, "title" => "Novo"}],
      DateTime.utc_now()
    )
    |> Repo.update!()

    send(view.pid, {:station_slot, "terror-anos-80", nil})
    assert has_element?(view, "#stations-terror-anos-80", "Novo")

    topic = StationPaths.viewers_topic("terror-anos-80")
    :ok = Phoenix.PubSub.subscribe(Streamix.PubSub, topic)
    {:ok, _} = Presence.track(self(), topic, "42", %{})

    # The page hears the same diff; once it reached us it reached the view.
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 5_000
    assert render(view) =~ "1 assistindo"
  end

  test "tuning in jumps to the film on air at the current minute", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/canais/terror-anos-80")
    assert to =~ ~r{^/watch/movie/11\?station=terror-anos-80&t=(89[5-9]|90[0-9])$}
  end

  test "an off-air station sends the viewer back to the list", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/canais", flash: flash}}} = live(conn, ~p"/canais/sumiu")
    assert flash["error"] =~ "fora do ar"
  end

  test "no stations, a plain empty state", %{conn: conn, station: station} do
    Repo.delete!(station)
    {:ok, view, _html} = live(conn, ~p"/canais")
    assert has_element?(view, "#stations-empty")
  end
end
