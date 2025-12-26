defmodule Streamix.Workers.SyncSeriesDetailsWorker do
  @moduledoc """
  Oban worker for syncing series details (seasons/episodes) in batches.

  Instead of syncing all series details at once (which can be 5000+ API calls),
  this worker processes series in configurable batches, spreading the load
  over time and allowing for better error handling and retries.

  ## Usage

  To queue all series for a provider in batches:

      SyncSeriesDetailsWorker.enqueue_all_for_provider(provider_id, batch_size: 50)

  To queue specific series:

      SyncSeriesDetailsWorker.new(%{series_ids: [1, 2, 3]}) |> Oban.insert()

  """
  use Oban.Worker,
    queue: :series_details,
    max_attempts: 3,
    priority: 2

  import Ecto.Query

  alias Streamix.Iptv.{Series, Sync}
  alias Streamix.Repo

  require Logger

  @default_batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_ids" => series_ids}}) do
    Logger.info("Syncing details for #{length(series_ids)} series")

    series_list = Repo.all(from s in Series, where: s.id in ^series_ids)

    results =
      series_list
      |> Task.async_stream(
        fn series ->
          case Sync.sync_series_details(series) do
            {:ok, _result} -> :ok
            {:error, _reason} -> :error
          end
        end,
        max_concurrency: 5,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{success: 0, failed: 0}, fn
        {:ok, :ok}, acc -> %{acc | success: acc.success + 1}
        {:ok, :error}, acc -> %{acc | failed: acc.failed + 1}
        {:exit, _}, acc -> %{acc | failed: acc.failed + 1}
      end)

    Logger.info("Batch completed: #{results.success} success, #{results.failed} failed")

    :ok
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
