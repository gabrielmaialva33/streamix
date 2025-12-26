defmodule Streamix.Workers.SyncAllProvidersWorker do
  @moduledoc """
  Periodic worker that triggers sync for all providers.
  Runs via Oban Cron plugin every 6 hours.

  Uses `:enqueue` strategy for series details, which queues background jobs
  to sync seasons/episodes in batches (50 series per batch by default).
  """

  use Oban.Worker, queue: :sync, max_attempts: 1

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.SyncProviderWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("Starting periodic sync for all providers")

    providers = Repo.all(Provider)
    count = length(providers)

    Logger.info("Found #{count} providers to sync")

    # Skip series details - they are synced on-demand when user accesses a series
    Enum.each(providers, fn provider ->
      SyncProviderWorker.enqueue(provider, series_details: :skip)
    end)

    Logger.info("Enqueued sync jobs for #{count} providers")

    :ok
  end
end
