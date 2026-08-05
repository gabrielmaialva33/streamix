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

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Sync.{Categories, Cleanup, Live, Movies, Series, Telemetry}
  alias Streamix.Repo

  require Logger

  # Delegate to sub-modules
  defdelegate sync_categories(provider), to: Categories
  defdelegate sync_live_channels(provider), to: Live
  defdelegate sync_movies(provider), to: Movies
  defdelegate sync_series(provider), to: Series
  defdelegate sync_series_details(series), to: Series
  defdelegate sync_all_series_details(provider), to: Series
  defdelegate cleanup_orphaned_user_data(), to: Cleanup
  defdelegate cleanup_orphaned_user_data(provider_id), to: Cleanup
  defdelegate cleanup_orphaned_user_data(provider_id, opts), to: Cleanup

  @post_sync_cleanup_limit 500

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
    start_time = Telemetry.sync_start(provider)

    update_status(provider, "syncing")

    # Emit progress: starting categories
    Telemetry.progress(provider, :categories, current: 0, total: 1)

    # First sync categories (required for live channel associations)
    case sync_categories(provider) do
      {:ok, _} ->
        Telemetry.progress(provider, :categories, current: 1, total: 1)
        # Then sync live, movies, series in parallel
        sync_content_parallel(provider, opts, start_time)

      {:error, reason} ->
        Telemetry.sync_stop(provider, start_time, :error, %{error: reason})
        update_status(provider, "failed")
        {:error, reason}
    end
  end

  # Sync live channels, movies, and series in parallel with graceful error handling
  defp sync_content_parallel(provider, opts, start_time) do
    # Emit progress: starting content sync (3 types)
    Telemetry.progress(provider, :content, current: 0, total: 3)

    tasks = [
      Task.async(fn ->
        result = safe_sync(fn -> sync_live_channels(provider) end)
        Telemetry.progress(provider, :content, current: 1, total: 3, type: :live)
        {:live, result}
      end),
      Task.async(fn ->
        result = safe_sync(fn -> sync_movies(provider) end)
        Telemetry.progress(provider, :content, current: 2, total: 3, type: :movies)
        {:movies, result}
      end),
      Task.async(fn ->
        result = safe_sync(fn -> sync_series(provider) end)
        Telemetry.progress(provider, :content, current: 3, total: 3, type: :series)
        {:series, result}
      end)
    ]

    # Wait for all tasks with a 10 minute timeout, catch exits gracefully
    results =
      try do
        tasks
        |> Task.await_many(:timer.minutes(10))
        |> Map.new()
      rescue
        e ->
          Logger.error("[Sync] Task timeout or crash: #{inspect(e)}")
          # Kill remaining tasks and return partial results
          Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
          %{live: {:error, :timeout}, movies: {:error, :timeout}, series: {:error, :timeout}}
      end

    handle_sync_results(provider, results, opts, start_time)
  end

  # Wrap sync functions to catch unexpected errors
  defp safe_sync(sync_fn) do
    sync_fn.()
  rescue
    e ->
      Logger.error("[Sync] Unexpected error: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.error("[Sync] Process exit: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  # Handle results with partial success support
  defp handle_sync_results(provider, results, opts, start_time) do
    live_result = results[:live] || {:error, :not_run}
    movies_result = results[:movies] || {:error, :not_run}
    series_result = results[:series] || {:error, :not_run}

    # Extract counts for successful syncs
    live_count = extract_count(live_result)
    vod_count = extract_count(movies_result)
    series_count = extract_count(series_result)

    # Collect failures
    failures =
      []
      |> maybe_add_failure(:live, live_result)
      |> maybe_add_failure(:movies, movies_result)
      |> maybe_add_failure(:series, series_result)

    counts = %{live: live_count, movies: vod_count, series: series_count}

    cond do
      # All succeeded
      Enum.empty?(failures) ->
        result = finalize_sync(provider, live_count, vod_count, series_count, opts)
        Telemetry.sync_stop(provider, start_time, :ok, counts)
        result

      # All failed
      length(failures) == 3 ->
        Telemetry.sync_stop(provider, start_time, :error, %{failures: failures})
        update_status(provider, "failed")
        Logger.error("[Sync] All sync types failed: #{inspect(failures)}")
        {:error, {:all_failed, failures}}

      # Partial success - log failures but continue
      true ->
        Logger.warning("[Sync] Partial sync failure: #{inspect(failures)}")

        result =
          finalize_partial_sync(provider, live_count, vod_count, series_count, failures, opts)

        Telemetry.sync_stop(provider, start_time, :partial, Map.put(counts, :failures, failures))
        result
    end
  end

  defp extract_count({:ok, count}) when is_integer(count), do: count
  defp extract_count(_), do: 0

  defp maybe_add_failure(failures, type, {:error, reason}), do: [{type, reason} | failures]
  defp maybe_add_failure(failures, _type, {:ok, _}), do: failures

  defp finalize_partial_sync(provider, live_count, vod_count, series_count, failures, opts) do
    with {:ok, details} <- handle_series_details(provider, opts) do
      now = DateTime.utc_now(:second)

      # Build update attrs only for successful syncs
      attrs =
        %{sync_status: "partial"}
        |> maybe_put(:live_channels_count, live_count, :live, failures)
        |> maybe_put(:movies_count, vod_count, :movies, failures)
        |> maybe_put(:series_count, series_count, :series, failures)
        |> maybe_put(:live_synced_at, now, :live, failures)
        |> maybe_put(:vod_synced_at, now, :movies, failures)
        |> maybe_put(:series_synced_at, now, :series, failures)

      update_sync_state(provider, attrs)

      failed_types = Enum.map(failures, fn {type, _} -> type end)

      Logger.info(
        "[Sync] Partial sync completed: #{live_count} live, #{vod_count} movies, " <>
          "#{series_count} series (failed: #{inspect(failed_types)})"
      )

      {:ok,
       %{
         live: live_count,
         movies: vod_count,
         series: series_count,
         details: details,
         failures: failures
       }}
    end
  end

  defp maybe_put(attrs, key, value, type, failures) do
    if Enum.any?(failures, fn {t, _} -> t == type end) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp finalize_sync(provider, live_count, vod_count, series_count, opts) do
    with {:ok, details} <- handle_series_details(provider, opts) do
      now = DateTime.utc_now(:second)

      update_sync_state(provider, %{
        sync_status: "completed",
        live_channels_count: live_count,
        movies_count: vod_count,
        series_count: series_count,
        live_synced_at: now,
        vod_synced_at: now,
        series_synced_at: now
      })

      Logger.info(
        "Full sync completed: #{live_count} live, #{vod_count} movies, #{series_count} series"
      )

      # Sweep catalog_items whose content row was removed by this sync's
      # orphan pass, plus the favorites/watch_progress/rooms that point at
      # them. Otherwise stranded catalog_items linger until the nightly
      # worker and can crash surfaces that join through them (see HomeLive).
      cleanup_provider_orphans(provider.id)

      {:ok, %{live: live_count, movies: vod_count, series: series_count, details: details}}
    end
  end

  defp cleanup_provider_orphans(provider_id) do
    case Cleanup.cleanup_orphaned_user_data(provider_id, limit: @post_sync_cleanup_limit) do
      {:ok, _counts} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Sync] Provider #{provider_id} cleanup deferred to scheduled worker: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "[Sync] Provider #{provider_id} cleanup deferred to scheduled worker: " <>
          Exception.message(error)
      )
  catch
    :exit, reason ->
      Logger.warning(
        "[Sync] Provider #{provider_id} cleanup exited and was deferred: #{inspect(reason)}"
      )
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

        with {:ok, job_count} <-
               SyncSeriesDetailsWorker.enqueue_all_for_provider(
                 provider.id,
                 batch_size: batch_size
               ) do
          Logger.info("Enqueued #{job_count} jobs for series details sync")
          {:ok, %{enqueued_jobs: job_count}}
        end

      # Backwards compatibility
      true ->
        sync_all_series_details(provider)

      false ->
        {:ok, nil}
    end
  end

  defp update_status(provider, status) do
    update_sync_state(provider, %{sync_status: status})
  end

  # A sync changes the provider status multiple times while callers keep the
  # struct they loaded before the run. Refresh before building the changeset:
  # otherwise Ecto can treat a terminal status as unchanged in memory and skip
  # the SQL update even though the database currently says "syncing".
  defp update_sync_state(provider, attrs) do
    Provider
    |> Repo.get!(provider.id)
    |> Provider.sync_changeset(attrs)
    |> Repo.update()
  end
end
