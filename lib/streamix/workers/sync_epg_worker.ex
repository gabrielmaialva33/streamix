defmodule Streamix.Workers.SyncEpgWorker do
  @moduledoc """
  Background worker for syncing EPG (Electronic Program Guide) data.
  Syncs program information for all live channels of a provider.

  Uses batching and rate limiting to avoid overwhelming the API.
  Has unique constraint to prevent duplicate syncs within 5 minutes.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 300, keys: [:provider_id]]

  alias Streamix.Iptv
  alias Streamix.Iptv.{Channels, EpgSync, Provider}

  require Logger

  @batch_size 50
  @batch_delay_ms 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}}) do
    case Iptv.get_provider(provider_id) do
      nil -> {:error, :provider_not_found}
      provider -> sync_all_epg(provider)
    end
  end

  defp sync_all_epg(%Provider{} = provider) do
    Logger.info("[SyncEpgWorker] Starting EPG sync for provider #{provider.id}")

    channels = get_epg_channels(provider.id)
    total = length(channels)

    Logger.info("[SyncEpgWorker] Found #{total} channels with EPG support")

    if total == 0 do
      :ok
    else
      process_all_channels(provider, channels, total)
    end
  end

  defp get_epg_channels(provider_id) do
    Channels.list(provider_id, limit: 10_000)
    |> Enum.filter(&(&1.epg_channel_id && &1.stream_id))
  end

  defp process_all_channels(provider, channels, total) do
    batch_count = ceil(total / @batch_size)

    results =
      channels
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce(%{synced: 0, programs: 0, failed: 0}, fn indexed_batch, acc ->
        process_batch_with_delay(provider, indexed_batch, batch_count, acc)
      end)

    finalize_sync(provider, results)
  end

  defp process_batch_with_delay(provider, {batch, batch_num}, batch_count, acc) do
    Logger.debug("[SyncEpgWorker] Processing batch #{batch_num}/#{batch_count}")

    batch_results = sync_batch(provider, batch)
    merged = merge_results(acc, batch_results)

    # Rate limit between batches (skip delay on last batch)
    if batch_num < batch_count, do: Process.sleep(@batch_delay_ms)

    merged
  end

  defp finalize_sync(provider, results) do
    EpgSync.update_epg_synced_at(provider)

    Logger.info(
      "[SyncEpgWorker] EPG sync completed for provider #{provider.id}: " <>
        "#{results.synced} channels, #{results.programs} programs, #{results.failed} failed"
    )

    broadcast_epg_sync_complete(provider, results)
    :ok
  end

  defp sync_batch(provider, channels) do
    channels
    |> Task.async_stream(
      fn channel ->
        EpgSync.sync_channel_epg(provider, channel.stream_id, channel.epg_channel_id)
      end,
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{synced: 0, programs: 0, failed: 0}, &accumulate_result/2)
  end

  defp accumulate_result({:ok, {:ok, count}}, acc) do
    %{acc | synced: acc.synced + 1, programs: acc.programs + count}
  end

  defp accumulate_result({:ok, {:error, _}}, acc), do: %{acc | failed: acc.failed + 1}
  defp accumulate_result({:exit, _}, acc), do: %{acc | failed: acc.failed + 1}

  defp merge_results(acc, batch) do
    %{
      synced: acc.synced + batch.synced,
      programs: acc.programs + batch.programs,
      failed: acc.failed + batch.failed
    }
  end

  defp broadcast_epg_sync_complete(provider, results) do
    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "provider:#{provider.id}",
      {:epg_sync_complete, :ok, results}
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
