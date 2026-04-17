defmodule StreamixWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus reporter — scraped via GET /metrics on the Phoenix endpoint.
      {TelemetryMetricsPrometheus.Core, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Prometheus histogram buckets (ms). Covers fast DB queries through slow
  # LiveView renders. Seconds-scale metrics get a separate bucket set.
  @latency_buckets_ms [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  @latency_buckets_s [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]

  def metrics do
    [
      # Phoenix Metrics
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),
      sum("phoenix.socket_drain.count"),
      distribution("phoenix.channel_joined.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms]
      ),

      # Database Metrics
      distribution("streamix.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms],
        description: "Total DB query time (decode + query + queue)"
      ),
      distribution("streamix.repo.query.query_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms],
        description: "The time spent executing the query"
      ),
      distribution("streamix.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms],
        description: "The time spent waiting for a database connection"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # IPTV Sync Metrics
      counter("streamix.sync.start.count",
        tags: [:provider_id],
        description: "Number of sync operations started"
      ),
      distribution("streamix.sync.stop.duration",
        tags: [:provider_id, :status],
        unit: {:native, :second},
        reporter_options: [buckets: @latency_buckets_s],
        description: "Duration of sync operations"
      ),
      last_value("streamix.sync.progress.percent",
        tags: [:provider_id, :phase],
        description: "Current sync progress percentage"
      ),
      counter("streamix.sync.batch.count",
        tags: [:provider_id, :type],
        description: "Number of batches processed"
      ),
      distribution("streamix.sync.batch.duration",
        tags: [:provider_id, :type],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms],
        description: "Duration of batch operations"
      ),
      distribution("streamix.sync.api_call.duration",
        tags: [:action, :status],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets_ms],
        description: "Duration of Xtream API calls"
      ),
      counter("streamix.sync.api_call.count",
        tags: [:action, :status],
        description: "Number of Xtream API calls"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {StreamixWeb, :count_users, []}
    ]
  end
end
