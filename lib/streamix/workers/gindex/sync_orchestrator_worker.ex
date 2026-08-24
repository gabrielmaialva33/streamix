defmodule Streamix.Workers.Gindex.SyncOrchestratorWorker do
  @moduledoc """
  Reconciles and finalizes one durable GIndex scan cycle.

  Progress comes from `gindex_scan_roots`, never from completed Oban rows. The
  worker may therefore outlive pruning, recreate missing jobs, and still report
  an exact terminal result.
  """

  use Oban.Worker,
    queue: :gindex_dispatch,
    max_attempts: 120,
    priority: 1,
    unique: [period: :timer.hours(1), fields: [:worker, :args], states: :incomplete]

  alias Streamix.Gindex
  alias Streamix.Providers
  alias Streamix.Workers.Gindex.BackfillTmdbWorker
  alias Streamix.Workers.SyncGindexProviderWorker

  require Logger

  @poll_interval 30

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"workflow_id" => cycle_id, "provider_id" => provider_id},
        attempt: attempt
      }) do
    summary = Gindex.scan_cycle_summary(provider_id, cycle_id)

    cond do
      summary.roots_total == 0 ->
        Logger.info("[GIndex Orchestrator] cycle=#{cycle_id} was superseded; stopping")
        :ok

      summary.settled? ->
        finalize(provider_id, cycle_id, summary)

      true ->
        reconcile(provider_id, cycle_id)
        delay = poll_interval(summary)

        Logger.info(
          "[GIndex Orchestrator] cycle=#{cycle_id} waiting " <>
            "done=#{summary.roots_completed}/#{summary.roots_total} " <>
            "failed=#{summary.roots_failed} paused=#{summary.roots_paused} " <>
            "attempt=#{attempt} next_check=#{delay}s"
        )

        {:snooze, delay}
    end
  end

  defp reconcile(provider_id, cycle_id) do
    case Providers.get_provider(provider_id) do
      nil ->
        :ok

      provider ->
        case SyncGindexProviderWorker.dispatch(provider, cycle_id: cycle_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[GIndex Orchestrator] cycle=#{cycle_id} reconciliation failed: " <>
                inspect(reason)
            )
        end
    end
  end

  defp poll_interval(%{next_resume_at: %DateTime{} = next_resume_at}) do
    max(@poll_interval, DateTime.diff(next_resume_at, DateTime.utc_now(), :second) + 5)
  end

  defp poll_interval(_summary), do: @poll_interval

  defp finalize(provider_id, cycle_id, summary) do
    status = final_status(summary)
    now = DateTime.utc_now(:second)

    attrs = %{
      sync_status: status,
      vod_synced_at: now,
      series_synced_at: now
    }

    case Providers.refresh_gindex_counts(provider_id, attrs) do
      {:ok, provider} ->
        Logger.info(
          "[GIndex Orchestrator] cycle=#{cycle_id} finalized status=#{status} " <>
            "roots=#{summary.roots_completed}/#{summary.roots_total} " <>
            "failed=#{summary.roots_failed} " <>
            "db_counts=#{inspect(%{movies: provider.movies_count, series: provider.series_count})}"
        )

        maybe_enqueue_enrich(provider, cycle_id)
        :ok

      {:error, :gindex_provider_not_found} ->
        Logger.warning("[GIndex Orchestrator] provider #{provider_id} no longer exists")
        :ok

      {:error, reason} ->
        {:error, {:provider_finalize_failed, reason}}
    end
  end

  defp final_status(%{roots_failed: 0, roots_with_skips: 0}), do: "completed"
  defp final_status(%{roots_completed: completed}) when completed > 0, do: "partial"
  defp final_status(_summary), do: "failed"

  defp maybe_enqueue_enrich(provider, cycle_id)
       when provider.movies_count > 0 or provider.series_count > 0 do
    case %{}
         |> BackfillTmdbWorker.new(schedule_in: 30)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id, conflict?: conflict}} ->
        Logger.info(
          "[GIndex Orchestrator] cycle=#{cycle_id} enqueued enrich job=#{id} " <>
            "conflict=#{conflict}"
        )

      {:error, reason} ->
        Logger.warning(
          "[GIndex Orchestrator] cycle=#{cycle_id} failed to enqueue enrich: " <>
            inspect(reason)
        )
    end
  end

  defp maybe_enqueue_enrich(_provider, _cycle_id), do: :ok
end
