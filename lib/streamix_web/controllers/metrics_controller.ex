defmodule StreamixWeb.MetricsController do
  @moduledoc """
  Exposes Prometheus metrics for scraping.

  Metrics are defined in `StreamixWeb.Telemetry` and collected by
  `TelemetryMetricsPrometheus.Core`. This controller just renders the
  current snapshot in the Prometheus text format.

  Protected by HTTP basic auth — see `StreamixWeb.Plugs.MetricsAuth`.
  """

  use StreamixWeb, :controller

  def scrape(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end
end
