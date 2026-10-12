defmodule Streamix.Workers.EmbedplayCanaryWorker do
  @moduledoc """
  Scheduled Embedplay resolution probe (see `Streamix.Embedplay.Canary`).

  Unique while in flight: the resolver drives a headless browser with only two
  slots, so a slow probe must never overlap the next tick. There are no
  retries — the next tick is the retry — and a failed probe is an expected
  observation, not a job error.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  @impl Oban.Worker
  def perform(_job) do
    _result = Streamix.Embedplay.run_canary()
    :ok
  end

  # One resolution plus connection setup and the database bookkeeping.
  @impl Oban.Worker
  def timeout(_job), do: Streamix.Embedplay.config(:resolve_timeout_ms, 45_000) + 15_000
end
