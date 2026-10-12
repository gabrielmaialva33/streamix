defmodule Streamix.Workers.SyncEmbedplayProviderWorker do
  @moduledoc """
  Embedplay movie catalog synchronization: daily from the crontab, or on
  demand from the admin. A no-op unless Embedplay is enabled.

  Skipped while resolution is degraded: importing more titles that cannot
  play would only widen the outage, and the catalog is hidden anyway. The
  next scheduled run after recovery picks the changes up.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: :timer.hours(1), fields: [:worker], states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Streamix.Embedplay.health() do
      %{status: :degraded, reason: reason} ->
        Logger.info("[Embedplay] catalog sync skipped: provider degraded (reason=#{reason})")
        :ok

      _health ->
        sync()
    end
  end

  defp sync do
    case Streamix.Embedplay.sync_catalog() do
      {:ok, _stats} -> :ok
      {:error, :embedplay_disabled} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
