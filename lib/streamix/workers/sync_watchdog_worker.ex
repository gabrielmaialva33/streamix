defmodule Streamix.Workers.SyncWatchdogWorker do
  @moduledoc """
  Reconciles `providers.sync_status` with the actual Oban job table.

  A provider can get stuck in `sync_status="syncing"` when:

    * the container is restarted while the worker holding the run is
      executing — Oban's Lifeline reschedules the job, but the
      orchestrator never gets a chance to flip the status
    * the orchestrator hits its safety-valve `@max_attempts` and
      finalizes as `failed`, but a new dispatch races in before the
      DB write commits and overwrites it back to `syncing`
    * a developer cancels a job manually mid-run

  This watchdog runs every 10 minutes and resets any provider stuck
  in `syncing` for more than 1 hour with no in-flight related Oban
  job. The reset goes to `failed` so the operator can see something
  went wrong (vs `idle` which would hide it).
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  require Logger

  # Workers that can hold the GIndex sync state. The watchdog only
  # resets a provider if NONE of these are in-flight for it.
  @gindex_workers [
    "Streamix.Workers.SyncGindexProviderWorker",
    "Streamix.Workers.Gindex.ScanRootWorker",
    "Streamix.Workers.Gindex.SyncOrchestratorWorker"
  ]

  # Xtream / global providers ride on this single worker.
  @xtream_worker "Streamix.Workers.SyncProviderWorker"

  @torrent_workers [
    "Streamix.Workers.SyncTorrentProviderWorker",
    "Streamix.Workers.Torrent.SyncSourceWorker",
    "Streamix.Workers.Torrent.SyncOrchestratorWorker"
  ]

  @in_flight_states ~w(available scheduled executing retryable)
  @stuck_threshold_minutes 60

  @impl Oban.Worker
  def perform(_job) do
    threshold =
      DateTime.utc_now()
      |> DateTime.add(-@stuck_threshold_minutes, :minute)
      |> DateTime.truncate(:second)
      |> DateTime.to_naive()

    stuck =
      from(p in Provider,
        where: p.sync_status == "syncing",
        where: p.updated_at < ^threshold
      )
      |> Repo.all()

    Enum.each(stuck, &maybe_reset/1)

    :ok
  end

  defp maybe_reset(%Provider{} = provider) do
    workers = workers_for(provider)

    in_flight =
      from(j in Oban.Job,
        where: j.worker in ^workers,
        where: j.state in ^@in_flight_states,
        where: fragment("(?->>'provider_id')::int = ?", j.args, ^provider.id),
        select: count(j.id)
      )
      |> Repo.one()

    if in_flight == 0 do
      Logger.warning(
        "[SyncWatchdog] provider #{provider.id} (#{provider.name}) stuck in syncing " <>
          ">#{@stuck_threshold_minutes}m with no in-flight jobs — resetting to failed"
      )

      Iptv.update_provider(provider, %{sync_status: "failed"})
    else
      Logger.debug(
        "[SyncWatchdog] provider #{provider.id} still has #{in_flight} in-flight jobs, leaving syncing"
      )

      :ok
    end
  end

  defp workers_for(%Provider{provider_type: :gindex}), do: @gindex_workers
  defp workers_for(%Provider{provider_type: :torrent}), do: @torrent_workers
  defp workers_for(_), do: [@xtream_worker]
end
