defmodule Streamix.Workers.CleanupOrphanedDataWorker do
  @moduledoc """
  Background worker for cleaning up orphaned favorites and watch history.

  Runs as a scheduled cron job (daily at 2 AM) to remove user data
  that references deleted content without blocking the sync process.

  Each execution deletes a bounded batch and snoozes the same Oban job
  while a full batch was found. That drains large backlogs incrementally
  without one unbounded transaction chain monopolizing PostgreSQL.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Streamix.Iptv.Sync.Cleanup

  require Logger

  @default_batch_size 5_000
  @snooze_seconds 5

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = batch_size(args)

    Logger.info("[CleanupWorker] Starting orphan batch limit=#{batch_size}")

    case Cleanup.cleanup_orphaned_user_data(nil, limit: batch_size) do
      {:ok, counts} ->
        Logger.info(
          "[CleanupWorker] Batch completed: #{counts.favorites} favorites, " <>
            "#{counts.watch_history} history, #{counts.watch_party_rooms} rooms, " <>
            "#{counts.catalog_items} catalog items removed"
        )

        # A concurrent sync may remove rows between selection and deletion,
        # making the deleted count smaller than the requested limit even
        # though more orphans remain. Continue until a zero-row proof.
        if counts.catalog_items > 0 do
          {:snooze, @snooze_seconds}
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("[CleanupWorker] Batch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp batch_size(%{"batch_size" => value}) when is_integer(value) and value > 0, do: value
  defp batch_size(_args), do: @default_batch_size
end
