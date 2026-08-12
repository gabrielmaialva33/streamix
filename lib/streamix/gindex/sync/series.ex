defmodule Streamix.Gindex.Sync.Series do
  @moduledoc """
  Checkpointed series synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.FolderBatch
  alias Streamix.Gindex.Sync.Persistence

  require Logger

  @default_batch_size 5
  @empty_stats %{series_count: 0, episodes_count: 0, skipped_count: 0}

  def sync(%{provider_id: _provider_id} = source, base_url, series_paths, opts \\ []) do
    Logger.info("[GIndex Sync] Starting series sync from #{length(series_paths)} paths")

    runtime_opts =
      Keyword.merge(
        [
          batch_size: @default_batch_size,
          empty_stats: @empty_stats,
          list_fun: &Scraper.list_series_folders/2,
          persist_fun: &upsert_batch/2,
          scrape_fun: &Scraper.scrape_single_series_result/2
        ],
        opts
      )

    Enum.reduce_while(series_paths, {:ok, @empty_stats}, fn path, {:ok, totals} ->
      case FolderBatch.run(source, base_url, path, runtime_opts) do
        {:ok, stats} ->
          {:cont, {:ok, merge_stats(totals, stats)}}

        {:error, reason} ->
          Logger.warning("[GIndex Sync] Failed to scrape series: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  rescue
    error ->
      Logger.error("[GIndex Sync] Error during series sync: #{inspect(error)}")
      {:error, error}
  end

  def upsert_batch(%{provider_id: _provider_id} = source, series_list)
      when is_list(series_list) do
    now = DateTime.utc_now(:second)

    Enum.reduce_while(series_list, {:ok, @empty_stats}, fn series_data, {:ok, acc} ->
      case Persistence.upsert_series_content(source, series_data, now) do
        {:ok, episode_count} ->
          {:cont,
           {:ok,
            %{
              series_count: acc.series_count + 1,
              episodes_count: acc.episodes_count + episode_count,
              skipped_count: acc.skipped_count
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  rescue
    error ->
      Logger.error("[GIndex Sync] Failed to upsert series batch: #{inspect(error)}")
      {:error, error}
  end

  defp merge_stats(left, right) do
    %{
      series_count: left.series_count + right.series_count,
      episodes_count: left.episodes_count + right.episodes_count,
      skipped_count: left.skipped_count + right.skipped_count
    }
  end
end
