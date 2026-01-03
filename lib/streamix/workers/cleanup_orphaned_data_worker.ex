defmodule Streamix.Workers.CleanupOrphanedDataWorker do
  @moduledoc """
  Background worker for cleaning up orphaned favorites and watch history.

  Runs as a scheduled cron job (daily at 2 AM) to remove user data
  that references deleted content without blocking the sync process.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Streamix.Iptv.Sync.Cleanup

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[CleanupWorker] Starting orphaned data cleanup...")

    {:ok, %{favorites: fav_count, watch_history: hist_count}} =
      Cleanup.cleanup_orphaned_user_data()

    Logger.info(
      "[CleanupWorker] Cleanup completed: #{fav_count} favorites, #{hist_count} history entries removed"
    )

    :ok
  end
end
