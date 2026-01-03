defmodule Streamix.Iptv.Sync do
  @moduledoc """
  Synchronization module for IPTV content.
  Fetches data from Xtream Codes API and syncs to database using UPSERT strategy.

  Uses INSERT ... ON CONFLICT UPDATE to preserve record IDs, which is critical
  for maintaining favorites and watch history references across syncs.

  This is a facade module that delegates to specialized sub-modules:
  - `Sync.Categories` - Category synchronization
  - `Sync.Live` - Live channel synchronization
  - `Sync.Movies` - Movie/VOD synchronization
  - `Sync.Series` - Series, seasons, and episodes synchronization
  - `Sync.Cleanup` - Orphaned user data cleanup
  """

  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Sync.{Categories, Cleanup, Live, Movies, Series}
  alias Streamix.Repo

  require Logger

  # Delegate to sub-modules
  defdelegate sync_categories(provider), to: Categories
  defdelegate sync_live_channels(provider), to: Live
  defdelegate sync_movies(provider), to: Movies
  defdelegate sync_series(provider), to: Series
  defdelegate sync_series_details(series), to: Series
  defdelegate sync_all_series_details(provider), to: Series
  defdelegate cleanup_orphaned_user_data, to: Cleanup

  @doc """
  Syncs all content from a provider (categories, live, vod, series).
  Uses UPSERT strategy to preserve record IDs for favorites/history references.

  ## Options

    * `:series_details` - How to handle series details (seasons/episodes):
      - `:skip` (default) - Don't sync series details
      - `:immediate` - Sync all series details immediately (slow, blocks)
      - `:enqueue` - Enqueue background jobs to sync in batches (recommended for production)

    * `:batch_size` - When using `:enqueue`, the number of series per batch job (default: 50)

  """
  def sync_all(%Provider{} = provider, opts \\ []) do
    Logger.info("Starting full sync for provider #{provider.id}")

    update_status(provider, "syncing")

    with {:ok, _} <- sync_categories(provider),
         {:ok, live_count} <- sync_live_channels(provider),
         {:ok, vod_count} <- sync_movies(provider),
         {:ok, series_count} <- sync_series(provider),
         {:ok, details} <- handle_series_details(provider, opts) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      provider
      |> Provider.sync_changeset(%{
        sync_status: "completed",
        live_channels_count: live_count,
        movies_count: vod_count,
        series_count: series_count,
        live_synced_at: now,
        vod_synced_at: now,
        series_synced_at: now
      })
      |> Repo.update()

      # NOTE: Orphaned data cleanup is now handled by CleanupOrphanedDataWorker (daily cron at 2 AM)

      Logger.info(
        "Full sync completed: #{live_count} live, #{vod_count} movies, #{series_count} series"
      )

      {:ok, %{live: live_count, movies: vod_count, series: series_count, details: details}}
    else
      {:error, reason} ->
        update_status(provider, "failed")
        {:error, reason}
    end
  end

  defp handle_series_details(provider, opts) do
    case Keyword.get(opts, :series_details, :skip) do
      :skip ->
        {:ok, nil}

      :immediate ->
        sync_all_series_details(provider)

      :enqueue ->
        alias Streamix.Workers.SyncSeriesDetailsWorker
        batch_size = Keyword.get(opts, :batch_size, 50)

        case SyncSeriesDetailsWorker.enqueue_all_for_provider(provider.id, batch_size: batch_size) do
          {:ok, job_count} ->
            Logger.info("Enqueued #{job_count} jobs for series details sync")
            {:ok, %{enqueued_jobs: job_count}}

          error ->
            error
        end

      # Backwards compatibility
      true ->
        sync_all_series_details(provider)

      false ->
        {:ok, nil}
    end
  end

  defp update_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end
end
