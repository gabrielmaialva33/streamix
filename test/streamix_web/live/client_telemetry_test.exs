defmodule StreamixWeb.ClientTelemetryTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  alias Streamix.Qoe.Event
  alias Streamix.Repo

  test "persists authenticated browser samples through the LiveView hook", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings")

    render_hook(view, "client_telemetry", %{
      "batch_id" => "live-browser-batch",
      "kind" => "web_vital",
      "event" => "page_vitals",
      "surface" => "settings",
      "lcp_ms" => 900
    })

    assert %Event{user_id: user_id, kind: "web_vital", lcp_ms: 900} = Repo.one!(Event)
    assert user_id == user.id
  end
end
