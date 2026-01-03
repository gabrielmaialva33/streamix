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

  alias Streamix.Iptv.Gindex
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

  ## Performance

  Categories are synced first (required for live channel associations).
  Then live channels, movies, and series are synced in parallel using Task.async
  for ~3x faster sync times.

  ## Options

    * `:series_details` - How to handle series details (seasons/episodes):
      - `:skip` (default) - Don't sync series details
      - `:immediate` - Sync all series details immediately (slow, blocks)
      - `:enqueue` - Enqueue background jobs to sync in batches (recommended for production)

    * `:batch_size` - When using `:enqueue`, the number of series per batch job (default: 50)

  """
  def sync_all(%Provider{provider_type: :gindex} = provider, _opts) do
    # Route GIndex providers to specialized sync module
    Gindex.Sync.sync_provider(provider)
  end

  def sync_all(%Provider{} = provider, opts) do
    Logger.info("Starting full sync for provider #{provider.id}")

    update_status(provider, "syncing")

    # First sync categories (required for live channel associations)
    case sync_categories(provider) do
      {:ok, _} ->
        # Then sync live, movies, series in parallel
        sync_content_parallel(provider, opts)

      {:error, reason} ->
        update_status(provider, "failed")
        {:error, reason}
    end
  end

  # Sync live channels, movies, and series in parallel
  defp sync_content_parallel(provider, opts) do
    tasks = [
      Task.async(fn -> {:live, sync_live_channels(provider)} end),
      Task.async(fn -> {:movies, sync_movies(provider)} end),
      Task.async(fn -> {:series, sync_series(provider)} end)
    ]

    # Wait for all tasks with a 10 minute timeout
    results =
      tasks
      |> Task.await_many(:timer.minutes(10))
      |> Map.new()

    case {results.live, results.movies, results.series} do
      {{:ok, live_count}, {:ok, vod_count}, {:ok, series_count}} ->
        finalize_sync(provider, live_count, vod_count, series_count, opts)

      {{:error, reason}, _, _} ->
        update_status(provider, "failed")
        {:error, {:live_sync_failed, reason}}

      {_, {:error, reason}, _} ->
        update_status(provider, "failed")
        {:error, {:movies_sync_failed, reason}}

      {_, _, {:error, reason}} ->
        update_status(provider, "failed")
        {:error, {:series_sync_failed, reason}}
    end
  end

  defp finalize_sync(provider, live_count, vod_count, series_count, opts) do
    case handle_series_details(provider, opts) do
      {:ok, details} ->
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

        Logger.info(
          "Full sync completed: #{live_count} live, #{vod_count} movies, #{series_count} series"
        )

        {:ok, %{live: live_count, movies: vod_count, series: series_count, details: details}}

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
