defmodule Streamix.Workers.SyncEpgWorker do
  @moduledoc """
  Background worker for syncing EPG (Electronic Program Guide) data.
  Syncs program information for all live channels of a provider.

  ## Error Handling

  - Uses batching and rate limiting to avoid overwhelming the API
  - If >80% of channels fail in a batch, snoozes the job (likely API issue)
  - Failed channels are tracked and can be retried
  - Has unique constraint to prevent duplicate syncs within 5 minutes

  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [period: 300, keys: [:provider_id]]

  alias Streamix.Iptv
  alias Streamix.Iptv.{Channels, EpgSync, Provider}

  require Logger

  @batch_size 50
  @batch_delay_ms 500
  @failure_threshold 0.8

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}, attempt: attempt}) do
    case Iptv.get_provider(provider_id) do
      nil -> {:error, :provider_not_found}
      provider -> sync_all_epg(provider, attempt)
    end
  end

  defp sync_all_epg(%Provider{} = provider, attempt) do
    Logger.info("[SyncEpgWorker] Starting EPG sync for provider #{provider.id} (attempt #{attempt})")

    channels = get_epg_channels(provider.id)
    total = length(channels)

    Logger.info("[SyncEpgWorker] Found #{total} channels with EPG support")

    if total == 0 do
      :ok
    else
      process_all_channels(provider, channels, total, attempt)
    end
  end

  defp get_epg_channels(provider_id) do
    Channels.list(provider_id, limit: 10_000)
    |> Enum.filter(&(&1.epg_channel_id && &1.stream_id))
  end

  defp process_all_channels(provider, channels, total, attempt) do
    batch_count = ceil(total / @batch_size)

    {results, high_failure_batch} =
      channels
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce_while({%{synced: 0, programs: 0, failed: 0, failed_channels: []}, nil}, fn indexed_batch, {acc, _} ->
        case process_batch_with_delay(provider, indexed_batch, batch_count) do
          {:ok, batch_results} ->
            merged = merge_results(acc, batch_results)
            {:cont, {merged, nil}}

          {:high_failure, batch_results, batch_num} ->
            merged = merge_results(acc, batch_results)
            {:halt, {merged, batch_num}}
        end
      end)

    # If we detected a high failure batch, snooze
    if high_failure_batch do
      snooze_seconds = min(60 * attempt, 300)

      Logger.warning(
        "[SyncEpgWorker] High failure rate in batch #{high_failure_batch}, " <>
          "snoozing for #{snooze_seconds}s"
      )

      {:snooze, snooze_seconds}
    else
      finalize_sync(provider, results)
    end
  end

  defp process_batch_with_delay(provider, {batch, batch_num}, batch_count) do
    Logger.debug("[SyncEpgWorker] Processing batch #{batch_num}/#{batch_count}")

    batch_results = sync_batch(provider, batch)

    # Rate limit between batches (skip delay on last batch)
    if batch_num < batch_count, do: Process.sleep(@batch_delay_ms)

    # Check for high failure rate in this batch
    batch_total = length(batch)
    failure_rate = if batch_total > 0, do: batch_results.failed / batch_total, else: 0.0

    if failure_rate >= @failure_threshold do
      {:high_failure, batch_results, batch_num}
    else
      {:ok, batch_results}
    end
  end

  defp finalize_sync(provider, results) do
    EpgSync.update_epg_synced_at(provider)

    total_processed = results.synced + results.failed
    failure_rate = if total_processed > 0, do: results.failed / total_processed, else: 0.0

    Logger.info(
      "[SyncEpgWorker] EPG sync completed for provider #{provider.id}: " <>
        "#{results.synced} channels, #{results.programs} programs, #{results.failed} failed " <>
        "(#{Float.round(failure_rate * 100, 1)}% failure rate)"
    )

    broadcast_epg_sync_complete(provider, results)
    :ok
  end

  defp sync_batch(provider, channels) do
    channels
    |> Task.async_stream(
      fn channel ->
        case EpgSync.sync_channel_epg(provider, channel.stream_id, channel.epg_channel_id) do
          {:ok, count} -> {:ok, channel, count}
          {:error, reason} -> {:error, channel, reason}
        end
      end,
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{synced: 0, programs: 0, failed: 0, failed_channels: []}, fn
      {:ok, {:ok, _channel, count}}, acc ->
        %{acc | synced: acc.synced + 1, programs: acc.programs + count}

      {:ok, {:error, channel, reason}}, acc ->
        Logger.debug("[SyncEpgWorker] Failed channel #{channel.id}: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1, failed_channels: [channel.id | acc.failed_channels]}

      {:exit, reason}, acc ->
        Logger.warning("[SyncEpgWorker] Task exit: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1}
    end)
  end

  defp merge_results(acc, batch) do
    %{
      synced: acc.synced + batch.synced,
      programs: acc.programs + batch.programs,
      failed: acc.failed + batch.failed,
      failed_channels: acc.failed_channels ++ batch.failed_channels
    }
  end

  defp broadcast_epg_sync_complete(provider, results) do
    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "provider:#{provider.id}",
      {:epg_sync_complete, :ok, Map.take(results, [:synced, :programs, :failed])}
    )
  end

  @doc """
  Enqueues an EPG sync job for the given provider.
  """
  def enqueue(%Provider{} = provider), do: enqueue(provider.id)

  def enqueue(provider_id) when is_integer(provider_id) or is_binary(provider_id) do
    %{provider_id: provider_id}
    |> new()
    |> Oban.insert()
  end
end
