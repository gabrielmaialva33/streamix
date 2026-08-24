defmodule StreamixWeb.PlayerLifecycleEndedTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.PlayerLifecycleTelemetry

  test "preserves ended as a bounded lifecycle state" do
    assert %{
             stage: "player_state_changed",
             from_state: "playing",
             to_state: "ended",
             state_reason: "media_ended"
           } =
             PlayerLifecycleTelemetry.normalize(%{
               "stage" => "player_state_changed",
               "from_state" => "playing",
               "to_state" => "ended",
               "state_reason" => "media_ended"
             })
  end
end
