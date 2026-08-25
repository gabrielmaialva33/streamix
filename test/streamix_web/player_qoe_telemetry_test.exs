defmodule StreamixWeb.PlayerQoeTelemetryTest do
  # Telemetry handlers are global and must not observe events from concurrent tests.
  use ExUnit.Case, async: false

  alias StreamixWeb.PlayerQoeTelemetry

  test "normalizes bounded numeric QoE measurements" do
    assert %{
             measurements: %{
               startup_ms: 350.5,
               rebuffer_count: 2,
               rebuffer_duration_ms: 1200,
               rebuffer_ratio: 0.15,
               live_latency: 3.2,
               frame_drop_ratio: 0.01
             },
             metadata: %{
               qoe_event: "finish",
               engine: "mpegts",
               live: true,
               reason: "ended"
             }
           } =
             PlayerQoeTelemetry.normalize(%{
               "qoe_event" => "finish",
               "engine" => "MPEGTS",
               "live" => true,
               "startup_ms" => "350.5",
               "rebuffer_count" => 2,
               "rebuffer_duration_ms" => 1200,
               "rebuffer_ratio" => 0.15,
               "live_latency" => 3.2,
               "frame_drop_ratio" => 0.01,
               "qoe_reason" => "ended"
             })
  end

  test "collapses unknown labels and invalid measurements" do
    normalized =
      PlayerQoeTelemetry.normalize(%{
        "qoe_event" => "custom-event-per-session",
        "engine" => "custom-engine-per-user",
        "startup_ms" => -10,
        "rebuffer_ratio" => "invalid",
        "qoe_reason" => "retry\nwith\tcontrol" <> String.duplicate("x", 200)
      })

    assert normalized.metadata.qoe_event == "unknown"
    assert normalized.metadata.engine == "unknown"
    assert normalized.measurements.startup_ms == 0
    assert normalized.measurements.rebuffer_ratio == 0
    assert String.length(normalized.metadata.reason) == 120
    refute normalized.metadata.reason =~ "\n"
    refute normalized.metadata.reason =~ "\t"
  end

  test "emits one bounded telemetry event for player_qoe payloads" do
    attach([:streamix, :player, :qoe])

    assert :ok =
             PlayerQoeTelemetry.observe(%{
               "stage" => "player_qoe",
               "qoe_event" => "playing",
               "engine" => "hls",
               "live" => false,
               "startup_ms" => 420,
               "stream_url" => "https://user:password@example.test/private.m3u8"
             })

    assert_receive {:telemetry, [:streamix, :player, :qoe], measurements, metadata}
    assert measurements.count == 1
    assert measurements.startup_ms == 420

    assert metadata == %{
             qoe_event: "playing",
             engine: "hls",
             live: false,
             reason: nil
           }

    refute inspect({measurements, metadata}) =~ "password"
  end

  test "ignores unrelated lifecycle events and malformed payloads" do
    attach([:streamix, :player, :qoe])

    assert :ok = PlayerQoeTelemetry.observe(%{"stage" => "player_engine_selected"})
    assert :ok = PlayerQoeTelemetry.observe(nil)
    assert :ok = PlayerQoeTelemetry.observe([])
    refute_receive {:telemetry, _, _, _}
  end

  test "telemetry metrics expose QoE measurements through Prometheus distributions" do
    metrics = StreamixWeb.Telemetry.metrics()
    names = Enum.map(metrics, & &1.name)

    assert [:streamix, :player, :qoe, :count] in names

    for measurement <- [
          :startup_ms,
          :rebuffer_duration_ms,
          :rebuffer_ratio,
          :live_latency,
          :frame_drop_ratio
        ] do
      metric = Enum.find(metrics, &(&1.name == [:streamix, :player, :qoe, measurement]))

      assert %Telemetry.Metrics.Distribution{} = metric
      assert metric.reporter_options[:buckets] != []
    end
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
