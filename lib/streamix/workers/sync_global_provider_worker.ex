defmodule Streamix.Workers.SyncGlobalProviderWorker do
  @moduledoc """
  Periodic worker that syncs the global provider (configured via env vars).
  Runs via Oban Cron plugin every 4 hours.

  Delegates to `SyncProviderWorker`, which owns the complete sync lifecycle and
  has provider-scoped uniqueness. The older RabbitMQ fan-out split categories
  into independent messages without a finalizer, leaving the provider stuck in
  `syncing` and allowing it to race the all-providers cron.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Streamix.Iptv.GlobalProvider
  alias Streamix.Workers.SyncProviderWorker

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
    case SyncProviderWorker.enqueue(provider, series_details: :skip) do
      {:ok, _job} ->
        Logger.info("[IPTV] Enqueued global provider sync")
        :ok

      {:error, reason} ->
        Logger.error("[IPTV] Failed to enqueue global provider sync: #{inspect(reason)}")
        {:error, {:enqueue_failed, reason}}
    end
  end
end
