defmodule Streamix.Workers.SyncAllProvidersWorker do
  @moduledoc """
  Periodic worker that triggers sync for all Xtream providers.
  Runs via Oban Cron plugin every 6 hours.

  GIndex providers are excluded — they have their own dispatcher
  (`Streamix.Workers.SyncGindexProviderWorker`) which fans out to
  per-root `ScanRootWorker`s with bounded timeouts. Routing them
  through this worker would also pull them into the legacy single-shot
  path (`Gindex.Sync.sync_provider/1`), duplicating work and racing
  the orchestrator-based fanout.

  Uses `:enqueue` strategy for series details, which queues background jobs
  to sync seasons/episodes in batches (50 series per batch by default).
  """

  use Oban.Worker, queue: :sync, max_attempts: 1

  import Ecto.Query

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.SyncProviderWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("Starting periodic sync for all providers")

    providers =
      from(p in Provider, where: p.provider_type != :gindex)
      |> Repo.all()

    count = length(providers)

    Logger.info("Found #{count} non-gindex providers to sync")

    # Skip series details - they are synced on-demand when user accesses a series
    Enum.each(providers, fn provider ->
      SyncProviderWorker.enqueue(provider, series_details: :skip)
    end)

    Logger.info("Enqueued sync jobs for #{count} providers")

    :ok
  end
end
