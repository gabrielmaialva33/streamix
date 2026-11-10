defmodule StreamixWeb.Telemetry.PrometheusCompactorTest do
  use ExUnit.Case, async: false

  alias StreamixWeb.Telemetry.PrometheusCompactor

  defp raw_samples, do: :ets.info(:prometheus_metrics_dist, :size)

  test "raw distribution samples are folded into buckets instead of piling up" do
    :ok = PrometheusCompactor.compact()

    for _ <- 1..25 do
      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{})
    end

    assert raw_samples() >= 25

    :ok = PrometheusCompactor.compact()

    assert raw_samples() == 0
    assert TelemetryMetricsPrometheus.Core.scrape() =~ "phoenix_endpoint_stop_duration"
  end
end
