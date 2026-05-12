defmodule Streamix.Workers.SyncAllProvidersWorker do
  @moduledoc """
  Periodic worker that triggers sync for Xtream providers only.
  Runs via Oban Cron plugin every 6 hours.

  GIndex has its own dispatcher (`SyncGindexProviderWorker`) that fans
  out to per-root `ScanRootWorker`s with bounded timeouts. Torrent
  aggregators are credential-less and run through
  `SyncTorrentProviderWorker`. Both would crash here:
  `XtreamClient.build_url/5` calls `URI.encode_www_form(nil)` on a
  torrent provider's empty username/password and FunctionClauseErrors
  the whole job. The previous `!= :gindex` filter accidentally pulled
  torrent rows in; matching on `== :xtream` keeps the worker honest.

  Uses `:enqueue` strategy for series details, which queues background
  jobs to sync seasons/episodes in batches (50 series per batch by
  default).
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
      from(p in Provider, where: p.provider_type == :xtream)
      |> Repo.all()

    count = length(providers)

    Logger.info("Found #{count} xtream providers to sync")

    # Skip series details - they are synced on-demand when user accesses a series
    Enum.each(providers, fn provider ->
      SyncProviderWorker.enqueue(provider, series_details: :skip)
    end)

    Logger.info("Enqueued sync jobs for #{count} providers")

    :ok
  end
end
