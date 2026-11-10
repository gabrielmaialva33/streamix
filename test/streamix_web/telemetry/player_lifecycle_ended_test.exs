defmodule StreamixWeb.Telemetry.PlayerLifecycleEndedTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Telemetry.PlayerLifecycle

  test "preserves ended as a bounded lifecycle state" do
    assert %{
             stage: "player_state_changed",
             from_state: "playing",
             to_state: "ended",
             state_reason: "media_ended"
           } =
             PlayerLifecycle.normalize(%{
               "stage" => "player_state_changed",
               "from_state" => "playing",
               "to_state" => "ended",
               "state_reason" => "media_ended"
             })
  end
end
