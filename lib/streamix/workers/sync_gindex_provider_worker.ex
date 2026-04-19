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

  alias Streamix.Iptv.Gindex.SyncPlanner
  alias Streamix.Iptv.GIndexProvider
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker

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
    roots = SyncPlanner.roots_for(provider)

    Logger.info(
      "[GIndex Dispatcher] enqueuing #{length(roots)} scan roots for provider #{provider.id}"
    )

    mark_status(provider, "syncing")

    results =
      Enum.map(roots, fn %{base_url: base_url, path: path, kind: kind} ->
        args = %{
          "provider_id" => provider.id,
          "base_url" => base_url,
          "path" => path,
          "kind" => Atom.to_string(kind)
        }

        args
        |> ScanRootWorker.new()
        |> Oban.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      Logger.warning("[GIndex Dispatcher] some roots failed to enqueue: #{inspect(errors)}")
      # Still return :ok — individual ScanRoot failures shouldn't nuke the
      # dispatch job, the children have their own retry policies.
      :ok
    end
  end

  defp mark_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end
end
