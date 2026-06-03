defmodule Streamix.Gindex.Sync.Animes do
  @moduledoc """
  Anime synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Persistence
  alias Streamix.Iptv.Provider

  require Logger

  @series_batch_size 5

  def sync(%Provider{} = provider, base_url, animes_path) do
    Logger.info("[GIndex Sync] Starting anime sync from: #{animes_path}")

    case Scraper.scrape_animes(base_url, animes_path) do
      {:ok, animes_list} ->
        Logger.info("[GIndex Sync] Found #{length(animes_list)} animes to sync")
        process_batches(provider, animes_list)

      {:error, reason} ->
        # Propagate. Old path returned {:ok, count: 0} which made the
        # ScanRootWorker think the run succeeded with an empty catalog,
        # so Oban marked the job completed and never retried even when
        # the upstream Cloudflare Worker was straight-up returning 500.
        Logger.warning("[GIndex Sync] Failed to scrape animes: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during anime sync: #{inspect(e)}")
      {:ok, %{animes_count: 0, episodes_count: 0}}
  end

  def upsert_batch(%Provider{} = provider, animes_list) when is_list(animes_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    total_episodes =
      Enum.reduce(animes_list, 0, fn anime_data, acc ->
        case Persistence.upsert_series_content(provider, anime_data, now, type_label: "anime") do
          {:ok, episode_count} -> acc + episode_count
          {:error, _} -> acc
        end
      end)

    {:ok, %{animes_count: length(animes_list), episodes_count: total_episodes}}
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert anime batch: #{inspect(e)}")
      {:error, e}
  end

  defp process_batches(provider, animes_list) do
    {total_animes, total_episodes} =
      animes_list
      |> Enum.chunk_every(@series_batch_size)
      |> Enum.reduce({0, 0}, &process_batch(provider, &1, &2))

    {:ok, %{animes_count: total_animes, episodes_count: total_episodes}}
  end

  defp process_batch(provider, batch, {animes_acc, episodes_acc}) do
    case upsert_batch(provider, batch) do
      {:ok, %{animes_count: count, episodes_count: episode_count}} ->
        {animes_acc + count, episodes_acc + episode_count}

      {:error, _} ->
        {animes_acc, episodes_acc}
    end
  end
end
