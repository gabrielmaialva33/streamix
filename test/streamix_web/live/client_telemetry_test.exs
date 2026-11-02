defmodule StreamixWeb.ClientTelemetryTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  alias Streamix.Qoe.Event
  alias Streamix.Repo

  test "persists playback explanations received through the LiveView ingestion boundary", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings")
    revision = String.duplicate("c", 40)

    render_hook(view, "client_telemetry", %{
      "batch_id" => Ecto.UUID.generate(),
      "kind" => "playback",
      "event" => "playback_session",
      "end_reason" => "recovery_deadline",
      "engine_reason" => "fallback_audio",
      "client_revision" => revision
    })

    event = Repo.one!(Event)
    assert Map.get(event, :end_reason) == "recovery_deadline"
    assert Map.get(event, :engine_reason) == "fallback_audio"
    assert Map.get(event, :client_revision) == revision
  end

  test "persists authenticated browser samples through the LiveView hook", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings")

    render_hook(view, "client_telemetry", %{
      "batch_id" => "live-browser-batch",
      "kind" => "web_vital",
      "event" => "page_vitals",
      "surface" => "settings",
      "device_class" => "mobile",
      "lcp_ms" => 900
    })

    assert %Event{
             user_id: user_id,
             kind: "web_vital",
             device_class: "mobile",
             lcp_ms: 900
           } = Repo.one!(Event)

    assert user_id == user.id
  end
end
