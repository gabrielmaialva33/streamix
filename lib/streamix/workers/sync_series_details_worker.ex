defmodule Streamix.Workers.SyncSeriesDetailsWorker do
  @moduledoc """
  Oban worker for syncing series details (seasons/episodes) in batches.

  Instead of syncing all series details at once (which can be 5000+ API calls),
  this worker processes series in configurable batches, spreading the load
  over time and allowing for better error handling and retries.

  ## Error Handling

  - Every failed or timed-out series fails the existing job
  - Oban retries the bounded batch at most five times with capped exponential backoff
  - Successful series may be refreshed again; no successor job resets the budget
  - Errors are logged without content identifiers

  ## Usage

  To queue all series for a provider in batches:

      SyncSeriesDetailsWorker.enqueue_all_for_provider(provider_id, batch_size: 50)

  To queue specific series:

      SyncSeriesDetailsWorker.new(%{series_ids: [1, 2, 3]}) |> Oban.insert()

  """
  use Oban.Worker,
    queue: :series_details,
    max_attempts: 5,
    priority: 2

  import Ecto.Query

  alias Streamix.Iptv.{Episode, Season, Series}
  alias Streamix.Repo
  alias Streamix.SafeLog

  require Logger

  @default_batch_size 50
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_ids" => series_ids}}) do
    series_list = Repo.all(from s in Series, where: s.id in ^series_ids)

    case process_batch(series_list) do
      0 ->
        :ok

      failed_count ->
        # Keep failure on this job: a fresh job would reset max_attempts and
        # introduce an insert failure that can silently lose pending work.
        {:error, {:series_sync_failed, failed_count}}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    exponent = attempt |> Kernel.-(1) |> max(0) |> min(4)
    min(60 * Integer.pow(2, exponent), 900)
  end

  defp process_batch(series_list) do
    Streamix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      series_list,
      &Streamix.Catalog.sync_series_details/1,
      max_concurrency: 2,
      timeout: Application.get_env(:streamix, :series_details_timeout_ms, 45_000),
      on_timeout: :kill_task
    )
    |> Enum.count(fn
      {:ok, {:ok, _result}} ->
        false

      {:ok, {:error, reason}} ->
        Logger.warning("Series detail synchronization failed",
          reason: SafeLog.redact_inspect(reason)
        )

        true

      {:exit, reason} ->
        Logger.warning("Series detail synchronization task exited",
          reason: SafeLog.redact_inspect(reason)
        )

        true
    end)
  end

  @doc """
  Enqueues all series from a provider for details sync, split into batches.

  ## Options

    * `:batch_size` - Number of series per job (default: 50)
    * `:only_missing` - Only sync series without episodes (default: true)
    * `:delay_between_batches` - Seconds between each batch job (default: 5)

  """
  def enqueue_all_for_provider(provider_id, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    only_missing = Keyword.get(opts, :only_missing, true)
    delay_seconds = Keyword.get(opts, :delay_between_batches, 5)

    query =
      from(s in Series,
        where: s.provider_id == ^provider_id,
        select: s.id,
        order_by: [asc: s.id]
      )

    query =
      if only_missing do
        # Only sync series that have zero episodes
        series_with_episodes =
          from(e in Episode,
            join: s in Season,
            on: e.season_id == s.id,
            select: s.series_id,
            distinct: true
          )

        where(query, [s], s.id not in subquery(series_with_episodes))
      else
        query
      end

    series_ids = Repo.all(query)
    total = length(series_ids)

    if total == 0 do
      Logger.info("No series to sync for provider #{provider_id}")
      {:ok, 0}
    else
      batches = Enum.chunk_every(series_ids, batch_size)
      batch_count = length(batches)

      Logger.info(
        "Enqueueing #{batch_count} jobs to sync #{total} series " <>
          "(#{batch_size} per batch, #{delay_seconds}s between batches)"
      )

      batches
      |> Enum.with_index()
      |> Enum.each(fn {batch_ids, index} ->
        scheduled_at = DateTime.add(DateTime.utc_now(), index * delay_seconds, :second)

        %{series_ids: batch_ids}
        |> __MODULE__.new(scheduled_at: scheduled_at)
        |> Oban.insert!()
      end)

      {:ok, batch_count}
    end
  end

  @doc """
  Returns the current sync progress for a provider.
  """
  def sync_progress(provider_id) do
    total = Repo.aggregate(from(s in Series, where: s.provider_id == ^provider_id), :count)

    series_with_episodes =
      from(e in Episode,
        join: s in Season,
        on: e.season_id == s.id,
        join: sr in Series,
        on: s.series_id == sr.id,
        where: sr.provider_id == ^provider_id,
        select: sr.id,
        distinct: true
      )

    synced = Repo.aggregate(series_with_episodes, :count)

    pending_jobs =
      Repo.aggregate(
        from(j in Oban.Job,
          where:
            j.queue == "series_details" and j.state in ["available", "scheduled", "executing"]
        ),
        :count
      )

    %{
      total: total,
      synced: synced,
      pending: total - synced,
      pending_jobs: pending_jobs,
      progress_percent: if(total > 0, do: Float.round(synced / total * 100, 1), else: 100.0)
    }
  end
end
