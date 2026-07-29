defmodule Streamix.Workers.Torrent.SyncOrchestratorWorker do
  @moduledoc """
  Finalizes one torrent-source fan-out after every sibling job settles.

  The dispatcher tags source jobs with a shared `workflow_id`. This worker
  polls cheaply while any sibling is in flight, then recomputes the provider
  count from PostgreSQL and writes one terminal status:

    * `completed` when every source completed
    * `partial` when at least one source completed and another failed
    * `failed` when no source completed
  """

  use Oban.Worker,
    queue: :torrent_sync,
    max_attempts: 120,
    priority: 1,
    unique: [
      period: :timer.hours(1),
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Torrent

  require Logger

  @source_worker "Streamix.Workers.Torrent.SyncSourceWorker"
  @in_flight_states ~w(available scheduled executing retryable)
  @poll_interval 30

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"provider_id" => provider_id, "workflow_id" => workflow_id} = args
      }) do
    if in_flight_count(workflow_id) > 0 do
      {:snooze, @poll_interval}
    else
      finalize(provider_id, workflow_id, Map.get(args, "dispatch_failures", 0))
    end
  end

  defp in_flight_count(workflow_id) do
    from(j in Oban.Job,
      where: j.worker == ^@source_worker,
      where: j.state in ^@in_flight_states,
      where: fragment("?->>'workflow_id' = ?", j.args, ^workflow_id),
      select: count(j.id)
    )
    |> Repo.one()
  end

  defp finalize(provider_id, workflow_id, dispatch_failures) do
    states =
      from(j in Oban.Job,
        where: j.worker == ^@source_worker,
        where: fragment("?->>'workflow_id' = ?", j.args, ^workflow_id),
        select: j.state
      )
      |> Repo.all()

    completed = Enum.count(states, &(&1 == "completed"))

    failed =
      dispatch_failures +
        Enum.count(states, &(&1 in ["cancelled", "discarded"]))

    status = terminal_status(completed, failed)

    Logger.info(
      "[Torrent Orchestrator] workflow=#{workflow_id} finalizing status=#{status} " <>
        "completed=#{completed} failed=#{failed}"
    )

    case Repo.get(Provider, provider_id) do
      nil ->
        Logger.warning("[Torrent Orchestrator] provider #{provider_id} not found")
        :ok

      provider ->
        case Torrent.refresh_provider_counts(provider, sync_status: status) do
          {:ok, _provider} -> :ok
          {:error, reason} -> {:error, {:provider_finalize_failed, reason}}
        end
    end
  end

  defp terminal_status(_completed, 0), do: "completed"
  defp terminal_status(completed, _failed) when completed > 0, do: "partial"
  defp terminal_status(_completed, _failed), do: "failed"
end
