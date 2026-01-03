defmodule Streamix.Workers.SyncGlobalProviderWorker do
  @moduledoc """
  Periodic worker that syncs the global provider (configured via env vars).
  Runs via Oban Cron plugin every 4 hours.

  When RabbitMQ is enabled, enqueues tasks to Broadway for distributed processing.
  Otherwise, runs sync directly in this process.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Streamix.Iptv.GlobalProvider
  alias Streamix.Queue

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if GlobalProvider.enabled?() do
      Logger.info("[IPTV] Starting sync for global provider")

      case GlobalProvider.ensure_exists!() do
        {:ok, provider} when is_struct(provider) ->
          Logger.info("[IPTV] Global provider exists: #{provider.name}")
          sync_global_provider(provider)

        {:ok, :disabled} ->
          Logger.info("[IPTV] Global provider is disabled, skipping sync")
          :ok

        {:error, reason} ->
          Logger.error("[IPTV] Failed to ensure global provider exists: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.debug("[IPTV] Global provider not configured, skipping sync")
      :ok
    end
  end

  defp sync_global_provider(provider) do
    if Queue.enabled?() do
      # Use Broadway for distributed processing
      Logger.info("[IPTV] Enqueueing sync via RabbitMQ/Broadway")
      Queue.enqueue_iptv_sync(provider)
    else
      # Direct execution
      sync_directly()
    end
  end

  defp sync_directly do
    case GlobalProvider.sync!() do
      {:ok, stats} ->
        Logger.info(
          "[IPTV] Global provider sync completed - Live: #{stats.live}, VOD: #{stats.vod}, Series: #{stats.series}"
        )

        :ok

      {:error, :not_found} ->
        Logger.warning("[IPTV] Global provider not found in database")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[IPTV] Global provider sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
