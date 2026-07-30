defmodule StreamixWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Telemetry

  test "exports callback latency for each LiveView lifecycle stage with a stable view tag" do
    stages = [:mount, :handle_params, :handle_event, :render]
    metrics = Telemetry.metrics()

    Enum.each(stages, fn stage ->
      metric =
        Enum.find(metrics, fn metric ->
          metric.name == [:phoenix, :live_view, stage, :stop, :duration]
        end)

      assert metric
      assert metric.tags == [:view]

      assert metric.tag_values.(%{
               socket: %{view: StreamixWeb.HomeLive},
               params: %{"unbounded" => "metadata is not used as a tag"}
             }).view == "StreamixWeb.HomeLive"
    end)
  end

  test "exports Core Web Vitals distributions by bounded device class" do
    metrics = Telemetry.metrics()

    Enum.each([:lcp_ms, :inp_ms, :cls_milli], fn vital ->
      metric =
        Enum.find(metrics, fn metric ->
          metric.name == [:streamix, :qoe, :event, vital]
        end)

      assert metric
      assert metric.tags == [:device_class]
    end)
  end
end
