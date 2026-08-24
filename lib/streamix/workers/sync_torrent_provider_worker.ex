defmodule Streamix.Workers.SyncTorrentProviderWorker do
  @moduledoc """
  Top-level dispatcher for torrent provider ingestion.

  Loads (or creates) the system torrent provider, then enqueues one
  `Streamix.Workers.Torrent.SyncSourceWorker` job per source returned
  by `Streamix.Torrent.sources/0`.

  Queue: `:torrent_sync`. Triggered nightly by the Oban cron plugin.
  Mirrors `Streamix.Workers.SyncGindexProviderWorker`.
  """

  use Oban.Worker,
    queue: :torrent_sync,
    max_attempts: 3,
    unique: [
      period: :timer.hours(1),
      fields: [:worker],
      states: :incomplete
    ]

  import Ecto.Query

  alias Streamix.Providers
  alias Streamix.Repo
  alias Streamix.Torrent
  alias Streamix.Workers.Torrent.{SyncOrchestratorWorker, SyncSourceWorker}

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if Providers.torrent_provider_enabled?() do
      Logger.info("[Torrent Dispatcher] ensuring provider exists")

      case Providers.ensure_torrent_provider() do
        {:ok, %{id: _} = provider} ->
          dispatch(provider)

        {:ok, :disabled} ->
          :ok

        {:error, reason} = err ->
          Logger.error("[Torrent Dispatcher] provider ensure failed: #{inspect(reason)}")
          err
      end
    else
      :ok
    end
  end

  defp dispatch(provider) do
    case active_workflow(provider.id) do
      nil -> start_workflow(provider)
      workflow_id -> log_duplicate(provider.id, workflow_id)
    end
  end

  defp start_workflow(provider) do
    sources = Torrent.sources()
    workflow_id = Ecto.UUID.generate()

    Logger.info(
      "[Torrent Dispatcher] workflow=#{workflow_id} enqueuing #{length(sources)} sources " <>
        "for provider #{provider.id}"
    )

    mark_status(provider, "syncing")

    dispatch_failures =
      Enum.count(sources, fn module ->
        args = %{
          "provider_id" => provider.id,
          "source_slug" => module.slug(),
          "workflow_id" => workflow_id
        }

        case args |> SyncSourceWorker.new() |> Oban.insert() do
          {:ok, %Oban.Job{}} ->
            false

          {:error, reason} ->
            Logger.error(
              "[Torrent Dispatcher] failed to enqueue #{module.slug()}: #{inspect(reason)}"
            )

            true
        end
      end)

    enqueue_orchestrator(provider.id, workflow_id, length(sources), dispatch_failures)
  end

  defp enqueue_orchestrator(provider_id, workflow_id, total_sources, dispatch_failures) do
    args = %{
      "provider_id" => provider_id,
      "workflow_id" => workflow_id,
      "total_sources" => total_sources,
      "dispatch_failures" => dispatch_failures
    }

    case args
         |> SyncOrchestratorWorker.new(schedule_in: 15)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id, conflict?: conflict}} ->
        Logger.info(
          "[Torrent Dispatcher] workflow=#{workflow_id} orchestrator job=#{id} " <>
            "conflict=#{conflict}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[Torrent Dispatcher] workflow=#{workflow_id} failed to enqueue orchestrator: " <>
            inspect(reason)
        )

        {:error, {:orchestrator_enqueue_failed, reason}}
    end
  end

  defp active_workflow(provider_id) do
    provider_id = Integer.to_string(provider_id)

    from(j in Oban.Job,
      where:
        j.worker in [
          "Streamix.Workers.Torrent.SyncSourceWorker",
          "Streamix.Workers.Torrent.SyncOrchestratorWorker"
        ],
      where: j.state in ~w(available scheduled executing retryable),
      where: fragment("?->>'provider_id' = ?", j.args, ^provider_id),
      # Jobs created before workflow orchestration don't have a workflow_id.
      # They still own this provider while active and must block a duplicate
      # full-catalog walk after a rolling deploy.
      select: fragment("COALESCE(?->>'workflow_id', 'legacy')", j.args),
      limit: 1
    )
    |> Repo.one()
  end

  defp log_duplicate(provider_id, workflow_id) do
    Logger.info(
      "[Torrent Dispatcher] provider #{provider_id} already has active workflow=" <>
        "#{workflow_id}; skipping duplicate dispatch"
    )

    :ok
  end

  defp mark_status(provider, status) do
    Providers.update_provider(provider, %{sync_status: status})
  end
end
