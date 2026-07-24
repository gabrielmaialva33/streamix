defmodule Streamix.Workers.SyncGindexProviderWorker do
  @moduledoc """
  Dispatcher for GIndex ingestion.

  This worker used to run the whole sync in one process, which routinely
  exceeded Oban's default timeout when the catalog had 10k+ titles and left
  the job stuck as `executing` forever. It now resolves the provider's scan
  roots (one per `{drive, path, kind}`) and enqueues a
  `Streamix.Workers.Gindex.ScanRootWorker` per root. Each child job carries
  its own timeout, retries, and rate-limited HTTP budget — so one bad path
  can't sabotage the rest of the catalog.

  Queue: `:gindex_dispatch`. Triggered nightly by the Oban cron plugin.
  """

  use Oban.Worker, queue: :gindex_dispatch, max_attempts: 3

  import Ecto.Query

  alias Streamix.Gindex.SyncPlanner
  alias Streamix.Iptv.GIndexProvider
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker
  alias Streamix.Workers.Gindex.SyncOrchestratorWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if GIndexProvider.enabled?() do
      Logger.info("[GIndex Dispatcher] ensuring provider exists")

      case GIndexProvider.ensure_exists!() do
        {:ok, %Provider{} = provider} ->
          dispatch(provider)

        {:ok, :disabled} ->
          :ok

        {:error, reason} = err ->
          Logger.error("[GIndex Dispatcher] provider ensure failed: #{inspect(reason)}")
          err
      end
    else
      :ok
    end
  end

  defp dispatch(provider) do
    case active_workflow(provider.id) do
      nil ->
        start_workflow(provider)

      workflow_id ->
        Logger.info(
          "[GIndex Dispatcher] provider #{provider.id} already has active workflow=" <>
            "#{workflow_id}; skipping duplicate dispatch"
        )

        :ok
    end
  end

  defp start_workflow(provider) do
    roots = SyncPlanner.roots_for(provider)
    # UUID tag that links every job in this dispatch together — the
    # orchestrator uses it to know which ScanRoot siblings belong to
    # the same sync run when it decides whether finalization is due.
    workflow_id = Ecto.UUID.generate()
    total_roots = length(roots)

    Logger.info(
      "[GIndex Dispatcher] workflow=#{workflow_id} enqueuing #{total_roots} scan roots " <>
        "for provider #{provider.id}"
    )

    mark_status(provider, "syncing")

    scan_results =
      Enum.map(roots, fn %{base_url: base_url, path: path, kind: kind} ->
        %{
          "provider_id" => provider.id,
          "base_url" => base_url,
          "path" => path,
          "kind" => Atom.to_string(kind),
          "workflow_id" => workflow_id
        }
        |> ScanRootWorker.new()
        |> Oban.insert()
      end)

    errors = Enum.filter(scan_results, &match?({:error, _}, &1))

    if errors != [] do
      Logger.warning("[GIndex Dispatcher] some roots failed to enqueue: #{inspect(errors)}")
    end

    # Fan-in job — open-source equivalent of Workflow.add_cascade(:finalize,
    # ..., deps: [:scan_root_1, ..., :scan_root_N]). Scheduled a few
    # seconds out so the ScanRoots have time to be picked up first;
    # otherwise the orchestrator's first poll would see 0 siblings
    # in-flight only because they haven't been fetched yet.
    orchestrator_args = %{
      "provider_id" => provider.id,
      "workflow_id" => workflow_id,
      "total_roots" => total_roots
    }

    case orchestrator_args
         |> SyncOrchestratorWorker.new(schedule_in: 15)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id, conflict?: conflict}} ->
        Logger.info(
          "[GIndex Dispatcher] workflow=#{workflow_id} orchestrator job=#{id} conflict=#{conflict}"
        )

      {:error, reason} ->
        Logger.error(
          "[GIndex Dispatcher] workflow=#{workflow_id} failed to enqueue orchestrator: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp active_workflow(provider_id) do
    provider_id = Integer.to_string(provider_id)

    from(j in Oban.Job,
      where:
        j.worker in [
          "Streamix.Workers.Gindex.ScanRootWorker",
          "Streamix.Workers.Gindex.SyncOrchestratorWorker"
        ],
      where: j.state in ~w(available scheduled executing retryable),
      where: fragment("?->>'provider_id' = ?", j.args, ^provider_id),
      select: fragment("?->>'workflow_id'", j.args),
      limit: 1
    )
    |> Repo.one()
  end

  defp mark_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end
end
