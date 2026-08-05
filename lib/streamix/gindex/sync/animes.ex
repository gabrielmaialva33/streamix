defmodule Streamix.Gindex.Sync.Animes do
  @moduledoc """
  Anime synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Persistence

  require Logger

  @series_batch_size 5

  def sync(%{provider_id: _provider_id} = source, base_url, animes_path) do
    Logger.info("[GIndex Sync] Starting anime sync from: #{animes_path}")

    case Scraper.scrape_animes(base_url, animes_path) do
      {:ok, animes_list} ->
        Logger.info("[GIndex Sync] Found #{length(animes_list)} animes to sync")
        process_batches(source, animes_list)

      {:error, reason} ->
        # Propagate. Old path returned {:ok, count: 0} which made the
        # ScanRootWorker think the run succeeded with an empty catalog,
        # so Oban marked the job completed and never retried even when
        # the upstream Cloudflare Worker was straight-up returning 500.
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

    Enum.reduce_while(
      animes_list,
      {:ok, %{animes_count: 0, episodes_count: 0}},
      fn anime_data, {:ok, stats} ->
        case Persistence.upsert_series_content(source, anime_data, now, type_label: "anime") do
          {:ok, episode_count} ->
            {:cont,
             {:ok,
              %{
                animes_count: stats.animes_count + 1,
                episodes_count: stats.episodes_count + episode_count
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  rescue
    error ->
      Logger.error("[GIndex Sync] Failed to upsert anime batch: #{inspect(error)}")
      {:error, error}
  end

  defp process_batches(source, animes_list) do
    animes_list
    |> Enum.chunk_every(@series_batch_size)
    |> Enum.reduce_while(
      {:ok, %{animes_count: 0, episodes_count: 0}},
      fn batch, {:ok, totals} ->
        case upsert_batch(source, batch) do
          {:ok, stats} ->
            {:cont,
             {:ok,
              %{
                animes_count: totals.animes_count + stats.animes_count,
                episodes_count: totals.episodes_count + stats.episodes_count
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end
end
