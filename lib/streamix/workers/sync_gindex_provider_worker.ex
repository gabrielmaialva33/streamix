defmodule Streamix.Workers.SyncGindexProviderWorker do
  @moduledoc """
  Reconciles the configured GIndex roots with durable scan state and Oban.

  Re-running this worker is safe: missing jobs are recreated, active jobs keep
  their cursor, and a new cycle starts only after the previous cycle settles.
  """

  use Oban.Worker,
    queue: :gindex_dispatch,
    max_attempts: 3,
    unique: [period: 30, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  alias Streamix.Gindex
  alias Streamix.Iptv
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker
  alias Streamix.Workers.Gindex.SyncOrchestratorWorker

  require Logger

  @scan_worker "Streamix.Workers.Gindex.ScanRootWorker"
  @in_flight_states ~w(available scheduled executing retryable)

  @impl Oban.Worker
  def perform(_job) do
    if Iptv.gindex_provider_enabled?() do
      Logger.info("[GIndex Dispatcher] ensuring provider exists")

      case Iptv.ensure_gindex_provider() do
        {:ok, %{id: _} = provider} ->
          dispatch(provider)

        {:ok, :disabled} ->
          :ok

        {:error, reason} = error ->
          Logger.error("[GIndex Dispatcher] provider ensure failed: #{inspect(reason)}")
          error
      end
    else
      :ok
    end
  end

  @doc false
  def dispatch(provider, opts \\ []) do
    with {:ok, cycle} <- resolve_cycle(provider, opts),
         :ok <- mark_cycle_status(provider.id, cycle.cycle_id),
         :ok <- enqueue_scan_roots(cycle.roots),
         :ok <- enqueue_orchestrator(provider.id, cycle.cycle_id, length(cycle.roots)) do
      action = if cycle.new_cycle?, do: "started", else: "reconciled"

      Logger.info(
        "[GIndex Dispatcher] #{action} cycle=#{cycle.cycle_id} " <>
          "provider=#{provider.id} roots=#{length(cycle.roots)}"
      )

      :ok
    end
  end

  defp resolve_cycle(provider, opts) do
    case Keyword.fetch(opts, :cycle_id) do
      {:ok, cycle_id} when is_binary(cycle_id) ->
        roots = Gindex.list_scan_cycle(provider.id, cycle_id)

        with :ok <- ensure_roots_present(roots) do
          {:ok, %{cycle_id: cycle_id, new_cycle?: false, roots: roots}}
        end

      {:ok, _invalid_cycle_id} ->
        {:error, :invalid_gindex_scan_cycle}

      :error ->
        ensure_configured_cycle(provider, opts)
    end
  end

  defp ensure_configured_cycle(provider, opts) do
    roots = Gindex.sync_roots_for(provider)

    with :ok <- ensure_roots_present(roots) do
      cycle_opts =
        cond do
          Gindex.active_scan_cycle_id(provider.id) ->
            []

          legacy = legacy_workflow(provider.id) ->
            [cycle_id: legacy.cycle_id, legacy_checkpoints: legacy.checkpoints]

          true ->
            []
        end

      with {:ok, cycle} <- Gindex.ensure_scan_cycle(provider.id, roots, cycle_opts) do
        maybe_reactivate_stalled_roots(provider.id, cycle, opts)
      end
    end
  end

  defp maybe_reactivate_stalled_roots(provider_id, cycle, opts) do
    reactivate? = Keyword.get(opts, :reactivate_stalled?, true)
    failed? = Enum.any?(cycle.roots, &(&1.status == "failed"))
    retryable? = Enum.any?(cycle.roots, &(&1.paused_reason == "retryable_error"))

    if reactivate? and not cycle.new_cycle? and (failed? or retryable?) do
      with {:ok, _roots} <- Gindex.reopen_failed_scan_roots(provider_id, cycle.cycle_id),
           {:ok, roots} <- Gindex.resume_retryable_scan_roots(provider_id, cycle.cycle_id) do
        {:ok, %{cycle | roots: roots}}
      else
        {:error, reason} -> {:error, {:stalled_scan_roots_reactivation_failed, reason}}
      end
    else
      {:ok, cycle}
    end
  end

  defp ensure_roots_present([]), do: {:error, :no_gindex_scan_roots}
  defp ensure_roots_present([_root | _roots]), do: :ok

  defp enqueue_scan_roots(roots) do
    roots
    |> Enum.filter(&(&1.status in ~w(pending running paused)))
    |> Enum.reduce_while(:ok, fn root, :ok ->
      args = %{
        "provider_id" => root.provider_id,
        "base_url" => root.base_url,
        "path" => root.root_path,
        "kind" => root.kind,
        "workflow_id" => root.cycle_id
      }

      case args
           |> ScanRootWorker.new(schedule_in: schedule_in(root.next_resume_at))
           |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: conflict}} ->
          Logger.debug(
            "[GIndex Dispatcher] cycle=#{root.cycle_id} root=#{root.kind}:#{root.root_path} " <>
              "conflict=#{conflict}"
          )

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:scan_root_enqueue_failed, root.id, reason}}}
      end
    end)
  end

  defp enqueue_orchestrator(provider_id, cycle_id, total_roots) do
    args = %{
      "provider_id" => provider_id,
      "workflow_id" => cycle_id,
      "total_roots" => total_roots
    }

    case args
         |> SyncOrchestratorWorker.new(schedule_in: 15)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id, conflict?: conflict}} ->
        Logger.debug(
          "[GIndex Dispatcher] cycle=#{cycle_id} orchestrator=#{id} conflict=#{conflict}"
        )

        :ok

      {:error, reason} ->
        {:error, {:orchestrator_enqueue_failed, reason}}
    end
  end

  defp mark_cycle_status(provider_id, cycle_id) do
    summary = Gindex.scan_cycle_summary(provider_id, cycle_id)

    status = cycle_status(summary)

    Iptv.update_gindex_sync(provider_id, %{sync_status: status})
  end

  defp cycle_status(%{roots_unfinished: unfinished, roots_paused_quota: quota})
       when unfinished > 0 and unfinished == quota,
       do: "paused_quota"

  defp cycle_status(%{
         roots_unfinished: unfinished,
         roots_paused_quota: quota,
         roots_paused_upstream: upstream
       })
       when unfinished > 0 and unfinished == quota + upstream,
       do: "paused_upstream"

  defp cycle_status(_summary), do: "syncing"

  defp legacy_workflow(provider_id) do
    provider_id = Integer.to_string(provider_id)

    jobs =
      from(job in Oban.Job,
        where: job.worker == ^@scan_worker,
        where: job.state in ^@in_flight_states,
        where: fragment("?->>'provider_id' = ?", job.args, ^provider_id),
        order_by: [desc: job.inserted_at, desc: job.id],
        select: %{args: job.args, meta: job.meta}
      )
      |> Repo.all()

    case Enum.find_value(jobs, & &1.args["workflow_id"]) do
      nil ->
        nil

      cycle_id ->
        checkpoints =
          jobs
          |> Enum.filter(&(&1.args["workflow_id"] == cycle_id))
          |> Map.new(fn job ->
            key = {job.args["path"], job.args["kind"]}
            meta = job.meta || %{}
            checkpoint = meta["checkpoint"] || meta["series_checkpoint"]
            {key, checkpoint}
          end)
          |> Map.reject(fn {_key, checkpoint} -> not is_map(checkpoint) end)

        %{cycle_id: cycle_id, checkpoints: checkpoints}
    end
  end

  defp schedule_in(nil), do: 0

  defp schedule_in(next_resume_at) do
    max(0, DateTime.diff(next_resume_at, DateTime.utc_now(), :second))
  end
end
