defmodule StreamixWeb.QoeBeaconControllerTest do
  use StreamixWeb.ConnCase, async: true

  import Ecto.Query

  alias Streamix.Qoe.Event
  alias Streamix.Repo

  @sample %{
    "batch_id" => "8c7f3f9e-1d2b-4a55-9a51-0d2f7b1c9e01",
    "kind" => "playback",
    "event" => "playback_session",
    "outcome" => "cancelled",
    "end_reason" => "navigation",
    "engine" => "avplayer",
    "content_type" => "vod",
    "device_class" => "mobile",
    "session_duration_ms" => 30_000
  }

  defp stored, do: Repo.all(from e in Event, where: e.event == "playback_session")

  test "a signed-in viewer's sample is stored once, however often it arrives", %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

    assert conn |> post(~p"/api/qoe/beacon", @sample) |> response(204)
    assert conn |> post(~p"/api/qoe/beacon", @sample) |> response(204)

    assert [%Event{end_reason: "navigation", device_class: "mobile"}] = stored()
    assert %{rows: [[nil]]} = Repo.query!("SELECT user_id FROM qoe_events")

    # LiveView and unload beacon share the same key and therefore deduplicate.
    assert {:ok, %{accepted: 0}} =
             Streamix.Qoe.record_client_event(
               Streamix.AccountsFixtures.library_key_fixture(user),
               @sample
             )

    %{conn: other_conn} = register_and_log_in_user(%{conn: build_conn()})
    assert other_conn |> post(~p"/api/qoe/beacon", @sample) |> response(204)
    assert length(stored()) == 2
  end

  test "an anonymous beacon is refused and stores nothing", %{conn: conn} do
    assert conn |> post(~p"/api/qoe/beacon", @sample) |> response(401)
    assert stored() == []
  end
end
