defmodule StreamixWeb.Telemetry.PrometheusCompactor do
  @moduledoc """
  Folds the Prometheus reporter's raw distribution samples into its histogram
  buckets once a minute.

  `TelemetryMetricsPrometheus.Core` keeps every distribution observation in
  ETS until a scrape aggregates it. Nothing scrapes `/metrics` in production,
  so after five days the table held 17.8 million samples and 3.3 GB. Running
  the same aggregation here bounds that table; the buckets are cumulative, so
  a Prometheus that scrapes later still reads correct counts.
  """

  use GenServer

  @interval :timer.minutes(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:compact, state) do
    compact()
    schedule(state.interval)
    {:noreply, state}
  end

  @doc false
  def compact do
    _text = TelemetryMetricsPrometheus.Core.scrape()
    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :compact, interval)
end
