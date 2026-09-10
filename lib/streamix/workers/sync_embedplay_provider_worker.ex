defmodule Streamix.Workers.SyncEmbedplayProviderWorker do
  @moduledoc "Manual, opt-in movie catalog synchronization; no automatic crawl on boot."

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: :timer.hours(1), fields: [:worker], states: :incomplete]

  @impl Oban.Worker
  def perform(_job) do
    case Streamix.Embedplay.sync_catalog() do
      {:ok, _stats} -> :ok
      {:error, :embedplay_disabled} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
