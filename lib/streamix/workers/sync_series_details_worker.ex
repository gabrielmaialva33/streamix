defmodule Streamix.Workers.SyncSeriesDetailsWorker do
  @moduledoc """
  Oban worker for syncing series details (seasons/episodes) in batches.

  Instead of syncing all series details at once (which can be 5000+ API calls),
  this worker processes series in configurable batches, spreading the load
  over time and allowing for better error handling and retries.

  ## Error Handling

  - Failed series are automatically re-enqueued with exponential backoff
  - If >80% of a batch fails, the job snoozes (likely API/network issue)
  - Individual failures don't block the entire batch
  - Failed series IDs are logged for debugging

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

  alias Streamix.Iptv.{Series, Sync}
  alias Streamix.Repo

  require Logger

  @default_batch_size 50
  @failure_threshold 0.8
  @retry_base_delay 60
  @max_retry_delay 900

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_ids" => series_ids}, attempt: attempt}) do
    total = length(series_ids)
    Logger.info("[SyncSeriesDetails] Processing #{total} series (attempt #{attempt})")

    series_list = Repo.all(from s in Series, where: s.id in ^series_ids)

    # Process batch and track individual results
    {successes, failures} = process_batch(series_list)

    success_count = length(successes)
    failure_count = length(failures)
    failure_rate = if total > 0, do: failure_count / total, else: 0.0

    Logger.info(
      "[SyncSeriesDetails] Batch completed: #{success_count} success, #{failure_count} failed " <>
        "(#{Float.round(failure_rate * 100, 1)}% failure rate)"
    )

    cond do
      # All succeeded
      failure_count == 0 ->
        :ok

      # High failure rate - likely API/network issue, snooze and retry entire batch
      failure_rate >= @failure_threshold ->
        snooze_seconds = min(@retry_base_delay * attempt, @max_retry_delay)

        Logger.warning(
          "[SyncSeriesDetails] High failure rate (#{Float.round(failure_rate * 100, 1)}%), " <>
            "snoozing for #{snooze_seconds}s"
        )

        {:snooze, snooze_seconds}

      # Partial failure - re-enqueue only failed items
      true ->
        failed_ids = Enum.map(failures, & &1.id)

        Logger.info(
          "[SyncSeriesDetails] Re-enqueueing #{failure_count} failed series: #{inspect(failed_ids)}"
        )

        schedule_retry_for_failures(failed_ids, attempt)
        :ok
    end
  end

  defp process_batch(series_list) do
    series_list
    |> Task.async_stream(
      fn series ->
        case Sync.sync_series_details(series) do
          {:ok, _result} -> {:ok, series}
          {:error, reason} -> {:error, series, reason}
        end
      end,
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, series}}, {successes, failures} ->
        {[series | successes], failures}

      {:ok, {:error, series, reason}}, {successes, failures} ->
        Logger.debug("[SyncSeriesDetails] Failed series #{series.id}: #{inspect(reason)}")
        {successes, [series | failures]}

      {:exit, reason}, {successes, failures} ->
        Logger.warning("[SyncSeriesDetails] Task exit: #{inspect(reason)}")
        {successes, failures}
    end)
  end

  defp schedule_retry_for_failures(failed_ids, attempt) do
    # Exponential backoff: 1min, 2min, 4min, 8min, capped at 15min
    delay_seconds = min(@retry_base_delay * :math.pow(2, attempt - 1) |> trunc(), @max_retry_delay)

    %{series_ids: failed_ids, retry_attempt: attempt + 1}
    |> __MODULE__.new(schedule_in: delay_seconds)
    |> Oban.insert()
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
        where(query, [s], s.episode_count == 0)
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

    synced =
      Repo.aggregate(
        from(s in Series, where: s.provider_id == ^provider_id and s.episode_count > 0),
        :count
      )

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
