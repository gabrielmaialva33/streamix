defmodule Streamix.Workers.SyncGlobalProviderWorker do
  @moduledoc """
  Periodic worker that syncs the global provider (configured via env vars).
  Runs via Oban Cron plugin every 4 hours.

  Only runs if the global provider is configured and enabled.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Streamix.Iptv.GlobalProvider

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if GlobalProvider.enabled?() do
      Logger.info("Starting sync for global provider")

      case GlobalProvider.ensure_exists!() do
        {:ok, provider} when is_struct(provider) ->
          Logger.info("Global provider exists: #{provider.name}")
          sync_global_provider()

        {:ok, :disabled} ->
          Logger.info("Global provider is disabled, skipping sync")
          :ok

        {:error, reason} ->
          Logger.error("Failed to ensure global provider exists: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.debug("Global provider not configured, skipping sync")
      :ok
    end
  end

  defp sync_global_provider do
    case GlobalProvider.sync!() do
      {:ok, stats} ->
        Logger.info(
          "Global provider sync completed - Live: #{stats.live}, VOD: #{stats.vod}, Series: #{stats.series}"
        )

        :ok

      {:error, :not_found} ->
        Logger.warning("Global provider not found in database")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Global provider sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
