defmodule StreamixWeb.PlayerLifecycleHandlersTest do
  # Telemetry handlers are global and must not observe events from concurrent tests.
  use ExUnit.Case, async: false

  alias StreamixWeb.PlayerLive
  alias StreamixWeb.WatchPartyLive.Show

  test "PlayerLive forwards lifecycle transitions to bounded telemetry" do
    attach([:streamix, :player, :state_transition])
    socket = %Phoenix.LiveView.Socket{}

    assert {:noreply, ^socket} =
             PlayerLive.handle_event(
               "player_lifecycle",
               %{
                 "stage" => "player_state_changed",
                 "engine" => "hls",
                 "from_state" => "loading",
                 "to_state" => "playing"
               },
               socket
             )

    assert_receive {:telemetry, [:streamix, :player, :state_transition], %{count: 1},
                    %{engine: "hls", from_state: "loading", to_state: "playing"}}
  end

  test "Watch Party forwards invalid lifecycle transitions to bounded telemetry" do
    attach([:streamix, :player, :state_transition_invalid])
    socket = %Phoenix.LiveView.Socket{}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "player_lifecycle",
               %{
                 "stage" => "player_state_transition_invalid",
                 "engine" => "mpegts",
                 "from_state" => "idle",
                 "to_state" => "playing",
                 "current_url" => "https://user:password@example.test/live.ts"
               },
               socket
             )

    assert_receive {:telemetry, [:streamix, :player, :state_transition_invalid], %{count: 1},
                    %{engine: "mpegts", from_state: "idle", to_state: "playing"}}
  end

  test "Prometheus metrics expose both state-transition counters" do
    names = Enum.map(StreamixWeb.Telemetry.metrics(), & &1.name)

    assert [:streamix, :player, :state_transition, :count] in names
    assert [:streamix, :player, :state_transition_invalid, :count] in names
  end

  defp attach(event_name) do
    handler_id = {__MODULE__, event_name, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
