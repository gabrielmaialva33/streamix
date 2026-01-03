defmodule Streamix.Workers.SyncGindexProviderWorker do
  @moduledoc """
  Periodic worker that syncs the GIndex provider (configured via env vars).
  Runs via Oban Cron plugin daily at 3 AM.

  When RabbitMQ is enabled, enqueues tasks to Broadway for distributed processing.
  Otherwise, runs sync directly in this process.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Streamix.Iptv.GIndexProvider
  alias Streamix.Queue

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if GIndexProvider.enabled?() do
      Logger.info("[GIndex] Starting sync for GIndex provider")

      case GIndexProvider.ensure_exists!() do
        {:ok, provider} when is_struct(provider) ->
          Logger.info("[GIndex] GIndex provider exists: #{provider.name}")
          sync_gindex_provider(provider)

        {:ok, :disabled} ->
          Logger.info("[GIndex] GIndex provider is disabled, skipping sync")
          :ok

        {:error, reason} ->
          Logger.error("[GIndex] Failed to ensure GIndex provider exists: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.debug("[GIndex] GIndex provider not configured, skipping sync")
      :ok
    end
  end

  defp sync_gindex_provider(provider) do
    if Queue.enabled?() do
      # Use Broadway for distributed processing
      Logger.info("[GIndex] Enqueueing sync via RabbitMQ/Broadway")
      Queue.enqueue_gindex_sync(provider)
    else
      # Direct execution
      sync_directly()
    end
  end

  defp sync_directly do
    case GIndexProvider.sync!() do
      {:ok, stats} ->
        Logger.info(
          "[GIndex] GIndex provider sync completed - " <>
            "Movies: #{stats.movies_count}, " <>
            "Series: #{Map.get(stats, :series_count, 0)}, " <>
            "Episodes: #{Map.get(stats, :episodes_count, 0)}"
        )

        :ok

      {:error, :not_found} ->
        Logger.warning("[GIndex] GIndex provider not found in database")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[GIndex] GIndex provider sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
