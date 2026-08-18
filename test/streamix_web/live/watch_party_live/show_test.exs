defmodule StreamixWeb.WatchPartyLive.ShowTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Streamix.IptvFixtures
  alias Streamix.Repo
  alias Streamix.WatchParty.Room

  setup :register_and_log_in_user

  setup %{user: user} do
    provider = IptvFixtures.provider_fixture(user)
    movie = IptvFixtures.movie_fixture(provider, %{name: "Party Movie"})

    room =
      %Room{}
      |> Room.create_changeset(%{host_user_id: user.id, catalog_item_id: movie.catalog_item_id})
      |> Repo.insert!()

    %{room: room, movie: movie}
  end

  describe "player events pushed by the shared VideoPlayer hook" do
    test "are all acknowledged instead of crashing the LiveView", %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/party/#{room.invite_code}/watch")

      # Every event assets/js/hooks/video_player.js can push. An unmatched
      # clause raises FunctionClauseError, which kills the LiveView and
      # remounts the hook — playback restarts from zero.
      events = [
        {"player_lifecycle",
         %{"stage" => "player_cleanup", "engine" => "native", "session_id" => 0}},
        {"ios_pwa_player_event", %{"event" => "visibilitychange", "content_id" => "1"}},
        {"progress_update", %{"position" => 12.0}},
        {"player_initializing", %{}},
        {"player_error", %{"message" => "boom"}},
        {"buffering", %{"buffering" => true}},
        {"duration_available", %{"duration" => 120.0}},
        {"update_watch_time", %{"duration" => 30}}
      ]

      for {event, payload} <- events do
        assert render_hook(view, event, payload)
        assert Process.alive?(view.pid), "LiveView died handling #{event}"
      end
    end
  end
end
