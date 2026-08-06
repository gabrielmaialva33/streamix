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

  alias Streamix.Gindex
  alias Streamix.Iptv
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.SyncOrchestratorWorker
  alias Streamix.Workers.SyncGindexProviderWorker

  require Logger

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

    stale_candidates =
      from(p in Provider,
        where:
          p.sync_status == "syncing" or
            (p.provider_type == :gindex and p.sync_status == "paused_quota"),
        where: p.updated_at < ^threshold
      )
      |> Repo.all()

    Enum.each(stale_candidates, &maybe_reset/1)

    :ok
  end

  defp maybe_reset(%Provider{provider_type: :gindex} = provider) do
    case Gindex.active_scan_cycle_id(provider.id) do
      nil -> reconcile_settled_gindex(provider)
      cycle_id -> reconcile_active_gindex(provider, cycle_id)
    end
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

  defp reconcile_active_gindex(provider, cycle_id) do
    summary = Gindex.scan_cycle_summary(provider.id, cycle_id)

    cond do
      quota_pause_active?(summary) ->
        Iptv.update_gindex_sync(provider.id, %{sync_status: "paused_quota"})

      stale_heartbeat?(summary.heartbeat_at) ->
        Logger.warning(
          "[SyncWatchdog] GIndex provider #{provider.id} cycle=#{cycle_id} has no recent " <>
            "durable progress; reconciling missing jobs"
        )

        SyncGindexProviderWorker.dispatch(provider)

      true ->
        :ok
    end
  end

  defp reconcile_settled_gindex(provider) do
    case Gindex.latest_scan_cycle_id(provider.id) do
      nil ->
        reset_provider(provider, "no durable scan cycle")

      cycle_id ->
        summary = Gindex.scan_cycle_summary(provider.id, cycle_id)
        reconcile_settled_cycle(provider, cycle_id, summary)
    end
  end

  defp reconcile_settled_cycle(provider, cycle_id, %{settled?: true} = summary) do
    %{
      "provider_id" => provider.id,
      "workflow_id" => cycle_id,
      "total_roots" => summary.roots_total
    }
    |> SyncOrchestratorWorker.new()
    |> Oban.insert()
    |> handle_finalizer_enqueue(provider)
  end

  defp reconcile_settled_cycle(provider, _cycle_id, _summary) do
    reset_provider(provider, "latest durable cycle has no active or terminal roots")
  end

  defp handle_finalizer_enqueue({:ok, _job}, _provider), do: :ok

  defp handle_finalizer_enqueue({:error, reason}, provider) do
    reset_provider(provider, "finalizer enqueue failed: #{inspect(reason)}")
  end

  defp quota_pause_active?(summary) do
    summary.roots_unfinished > 0 and
      summary.roots_unfinished == summary.roots_paused_quota and
      match?(%DateTime{}, summary.next_resume_at) and
      DateTime.compare(summary.next_resume_at, DateTime.utc_now()) == :gt
  end

  defp stale_heartbeat?(nil), do: true

  defp stale_heartbeat?(heartbeat) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stuck_threshold_minutes, :minute)
    DateTime.compare(heartbeat, cutoff) == :lt
  end

  defp reset_provider(provider, reason) do
    Logger.warning(
      "[SyncWatchdog] GIndex provider #{provider.id} stuck in syncing: #{reason}; " <>
        "resetting to failed"
    )

    Iptv.update_gindex_sync(provider.id, %{sync_status: "failed"})
  end

  defp workers_for(%Provider{provider_type: :torrent}), do: @torrent_workers
  defp workers_for(_), do: [@xtream_worker]
end
