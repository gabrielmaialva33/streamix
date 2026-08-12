defmodule Streamix.Gindex.Sync.Animes do
  @moduledoc """
  Checkpointed anime synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.FolderBatch
  alias Streamix.Gindex.Sync.Persistence

  require Logger

  @default_batch_size 5
  @empty_stats %{animes_count: 0, episodes_count: 0, skipped_count: 0}

  def sync(%{provider_id: _provider_id} = source, base_url, animes_path, opts \\ []) do
    Logger.info("[GIndex Sync] Starting anime sync from: #{animes_path}")

    runtime_opts =
      Keyword.merge(
        [
          batch_size: @default_batch_size,
          empty_stats: @empty_stats,
          list_fun: &Scraper.list_anime_folders/2,
          persist_fun: &upsert_batch/2,
          scrape_fun: &Scraper.scrape_single_anime_result/2
        ],
        opts
      )

    case FolderBatch.run(source, base_url, animes_path, runtime_opts) do
      {:ok, stats} ->
        {:ok, stats}

      {:error, reason} ->
        Logger.warning("[GIndex Sync] Failed to scrape animes: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("[GIndex Sync] Error during anime sync: #{inspect(error)}")
      {:error, error}
  end

  def upsert_batch(%{provider_id: _provider_id} = source, animes_list)
      when is_list(animes_list) do
    now = DateTime.utc_now(:second)

    Enum.reduce_while(animes_list, {:ok, @empty_stats}, fn anime_data, {:ok, stats} ->
      case Persistence.upsert_series_content(source, anime_data, now, type_label: "anime") do
        {:ok, episode_count} ->
          {:cont,
           {:ok,
            %{
              animes_count: stats.animes_count + 1,
              episodes_count: stats.episodes_count + episode_count,
              skipped_count: stats.skipped_count
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  rescue
    error ->
      Logger.error("[GIndex Sync] Failed to upsert anime batch: #{inspect(error)}")
      {:error, error}
  end
end
