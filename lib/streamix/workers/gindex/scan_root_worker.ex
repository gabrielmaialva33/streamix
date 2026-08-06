defmodule Streamix.Workers.Gindex.ScanRootWorker do
  @moduledoc """
  Executes one bounded, resumable GIndex scan root.

  Durable progress lives in `gindex_scan_roots`; Oban only owns execution and
  retry timing. That separation lets a deployment, Lifeline recovery, or Pruner
  cleanup resume from the last committed batch instead of page zero.
  """

  use Oban.Worker,
    queue: :gindex_scan,
    max_attempts: 12,
    priority: 1,
    unique: [
      period: :timer.hours(48),
      fields: [:worker, :args],
      keys: [:provider_id, :path, :kind],
      states: :incomplete
    ]

  alias Streamix.Gindex
  alias Streamix.Iptv
  alias Streamix.Repo

  require Logger

  @timeout :timer.hours(2)
  @slice_resume_seconds 5
  @max_slice_requests 1_500

  @impl Oban.Worker
  def timeout(_job), do: @timeout

  @impl Oban.Worker
  def perform(job) do
    perform_with(job, &Gindex.sync_kind/5, &Gindex.seconds_until_quota_reset/0)
  end

  @doc false
  def perform_with(
        %Oban.Job{
          args: %{
            "provider_id" => provider_id,
            "base_url" => base_url,
            "path" => path,
            "kind" => kind
          }
        } = job,
        sync_fun,
        reset_delay_fun
      ) do
    with %{id: _} = provider <- Iptv.get_provider(provider_id),
         {:ok, kind_atom} <- parse_kind(kind),
         {:ok, scan_root} <- load_scan_root(job, provider_id, base_url, path, kind),
         {:ok, scan_root} <- Gindex.mark_scan_root_running(scan_root) do
      mark_provider_status(provider_id, "syncing")
      started_at = System.monotonic_time(:millisecond)
      request_budget = request_budget(provider_id, scan_root.cycle_id)

      Logger.info(
        "[GIndex ScanRoot] start cycle=#{scan_root.cycle_id} provider=#{provider_id} " <>
          "kind=#{kind} path=#{path} budget=#{request_budget}"
      )

      result =
        Gindex.run_with_request_budget(request_budget, fn ->
          sync_fun.(
            provider,
            scan_root.base_url,
            scan_root.root_path,
            kind_atom,
            sync_opts(scan_root, job, scan_root.root_path)
          )
        end)

      handle_result(
        result,
        job,
        scan_root,
        provider_id,
        kind_atom,
        path,
        started_at,
        reset_delay_fun
      )
    else
      nil ->
        Logger.warning("[GIndex ScanRoot] provider #{provider_id} not found, discarding")
        {:cancel, :provider_not_found}

      {:error, :invalid_kind} ->
        Logger.warning("[GIndex ScanRoot] invalid kind #{inspect(kind)}, discarding")
        {:cancel, :invalid_kind}

      {:error, :superseded_cycle} ->
        Logger.info(
          "[GIndex ScanRoot] cycle=#{job.args["workflow_id"]} superseded for " <>
            "provider=#{provider_id} kind=#{kind} path=#{path}; cancelling stale job"
        )

        {:cancel, :superseded_cycle}

      {:error, reason} = error ->
        Logger.error(
          "[GIndex ScanRoot] could not initialize durable state provider=#{provider_id} " <>
            "kind=#{kind} path=#{path}: #{inspect(reason)}"
        )

        error
    end
  end

  defp handle_result(
         {:ok, stats},
         job,
         scan_root,
         provider_id,
         kind,
         path,
         started_at,
         _reset_delay_fun
       ) do
    took_ms = System.monotonic_time(:millisecond) - started_at

    with {:ok, _root} <- Gindex.complete_scan_root(scan_root, stats) do
      Logger.info(
        "[GIndex ScanRoot] done cycle=#{scan_root.cycle_id} provider=#{provider_id} " <>
          "kind=#{kind} path=#{path} stats=#{inspect(stats)} took=#{took_ms}ms"
      )

      :telemetry.execute(
        [:streamix, :gindex, :scan_root, :stop],
        %{duration_ms: took_ms},
        %{provider_id: provider_id, kind: kind, path: path, stats: stats}
      )

      write_meta(job, %{
        "kind" => Atom.to_string(kind),
        "path" => path,
        "stats" => stringify_stats(stats),
        "took_ms" => took_ms,
        "paused_reason" => nil,
        "quota_count" => nil,
        "checkpoint" => nil,
        "series_checkpoint" => nil,
        "checkpoint_path" => nil
      })

      recount_provider(provider_id)
      :ok
    end
  end

  defp handle_result(
         {:error, {:quota_exhausted, count}},
         job,
         scan_root,
         provider_id,
         kind,
         path,
         _started_at,
         reset_delay_fun
       ) do
    delay = reset_delay_fun.()
    next_resume_at = DateTime.add(DateTime.utc_now(), delay, :second)

    with {:ok, _root} <-
           Gindex.pause_scan_root(scan_root, :quota_exhausted,
             quota_count: count,
             next_resume_at: next_resume_at
           ) do
      write_meta(job, %{"paused_reason" => "quota_exhausted", "quota_count" => count})
      mark_provider_status(provider_id, "paused_quota")

      Logger.warning(
        "[GIndex ScanRoot] quota exhausted at #{count}; pausing provider=#{provider_id} " <>
          "kind=#{kind} path=#{path} for #{delay}s until the next UTC window"
      )

      {:snooze, delay}
    end
  end

  defp handle_result(
         {:error, {:slice_exhausted, count}},
         job,
         scan_root,
         provider_id,
         kind,
         path,
         _started_at,
         _reset_delay_fun
       ) do
    next_resume_at = DateTime.add(DateTime.utc_now(), @slice_resume_seconds, :second)

    with {:ok, _root} <-
           Gindex.pause_scan_root(scan_root, :slice_exhausted, next_resume_at: next_resume_at) do
      write_meta(job, %{"paused_reason" => "slice_exhausted", "slice_count" => count})

      Logger.info(
        "[GIndex ScanRoot] yielded after #{count} requests provider=#{provider_id} " <>
          "kind=#{kind} path=#{path}"
      )

      {:snooze, @slice_resume_seconds}
    end
  end

  defp handle_result(
         {:error, reason} = error,
         job,
         scan_root,
         provider_id,
         kind,
         path,
         _started_at,
         _reset_delay_fun
       ) do
    final_attempt? = job.attempt >= job.max_attempts

    state_result =
      if final_attempt? do
        Gindex.fail_scan_root(scan_root, reason)
      else
        Gindex.pause_scan_root(scan_root, :retryable_error, error: reason)
      end

    case state_result do
      {:ok, _root} ->
        write_meta(job, %{
          "paused_reason" => if(final_attempt?, do: nil, else: "retryable_error"),
          "last_error" => inspect(reason, limit: 20, printable_limit: 1_000)
        })

        Logger.warning(
          "[GIndex ScanRoot] failed provider=#{provider_id} kind=#{kind} path=#{path} " <>
            "final_attempt=#{final_attempt?} reason=#{inspect(reason)}"
        )

        error

      {:error, state_reason} ->
        {:error, {:scan_state_update_failed, state_reason, reason}}
    end
  end

  defp load_scan_root(job, provider_id, base_url, path, kind) do
    cycle_id = Map.get(job.args, "workflow_id") || Ecto.UUID.generate()

    case Gindex.get_scan_root(provider_id, path, kind) do
      nil ->
        checkpoint = legacy_checkpoint(job)
        checkpoints = if is_map(checkpoint), do: %{{path, kind} => checkpoint}, else: %{}

        case Gindex.ensure_scan_cycle(
               provider_id,
               [%{base_url: base_url, path: path, kind: String.to_existing_atom(kind)}],
               cycle_id: cycle_id,
               legacy_checkpoints: checkpoints
             ) do
          {:ok, %{roots: [root]}} -> {:ok, root}
          {:error, reason} -> {:error, reason}
        end

      %{cycle_id: ^cycle_id} = root ->
        {:ok, root}

      _root ->
        {:error, :superseded_cycle}
    end
  end

  defp sync_opts(scan_root, job, path) do
    checkpoint =
      case scan_root.cursor do
        cursor when is_map(cursor) and map_size(cursor) > 0 -> cursor
        _ -> legacy_checkpoint(job)
      end

    [
      checkpoint: checkpoint,
      on_checkpoint: fn checkpoint ->
        case Gindex.checkpoint_scan_root(scan_root, checkpoint) do
          {:ok, _root} ->
            meta = %{
              "checkpoint" => checkpoint,
              "checkpoint_path" => path
            }

            meta =
              if job.args["kind"] == "series" do
                Map.put(meta, "series_checkpoint", checkpoint)
              else
                meta
              end

            write_meta(job, meta)

            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    ]
  end

  defp legacy_checkpoint(job) do
    meta = job.meta || %{}
    Map.get(meta, "checkpoint") || Map.get(meta, "series_checkpoint")
  end

  defp request_budget(provider_id, cycle_id) do
    %{remaining: remaining} = Gindex.quota_status()
    %{roots_unfinished: unfinished} = Gindex.scan_cycle_summary(provider_id, cycle_id)

    remaining
    |> max(1)
    |> div(max(unfinished, 1))
    |> max(1)
    |> min(@max_slice_requests)
  end

  defp parse_kind("movies"), do: {:ok, :movies}
  defp parse_kind("series"), do: {:ok, :series}
  defp parse_kind("animes"), do: {:ok, :animes}
  defp parse_kind(_kind), do: {:error, :invalid_kind}

  defp stringify_stats(stats) when is_map(stats) do
    for {key, value} <- stats, into: %{}, do: {to_string(key), value}
  end

  defp write_meta(%Oban.Job{id: id}, payload) do
    case Repo.get(Oban.Job, id) do
      nil ->
        :telemetry.execute(
          [:streamix, :gindex, :scan_root, :meta_write_failed],
          %{count: 1},
          %{reason: :job_not_found, job_id: id}
        )

        {:error, :job_not_found}

      job ->
        job
        |> Ecto.Changeset.change(meta: Map.merge(job.meta || %{}, payload))
        |> Repo.update()
        |> case do
          {:ok, _job} ->
            :ok

          {:error, changeset} ->
            Logger.error(
              "[GIndex ScanRoot] meta write failed for job #{id}: " <>
                inspect(changeset.errors)
            )

            :telemetry.execute(
              [:streamix, :gindex, :scan_root, :meta_write_failed],
              %{count: 1},
              %{reason: :update_failed, job_id: id, errors: changeset.errors}
            )

            {:error, :meta_write_failed}
        end
    end
  end

  defp recount_provider(provider_id) do
    case Iptv.refresh_gindex_counts(provider_id) do
      {:ok, _provider} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[GIndex ScanRoot] provider #{provider_id} recount failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_provider_status(provider_id, status) do
    case Iptv.update_gindex_sync(provider_id, %{sync_status: status}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[GIndex ScanRoot] status update failed: #{inspect(reason)}")
    end
  end
end
