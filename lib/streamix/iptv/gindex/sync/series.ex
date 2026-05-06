defmodule Streamix.Iptv.Gindex.Sync.Series do
  @moduledoc """
  Series synchronization for GIndex providers.
  """

  alias Streamix.Iptv.Gindex.Scraper
  alias Streamix.Iptv.Gindex.Sync.Persistence
  alias Streamix.Iptv.Provider

  require Logger

  @series_batch_size 5

  def sync(%Provider{} = provider, base_url, series_paths) do
    Logger.info("[GIndex Sync] Starting series sync from #{length(series_paths)} paths")

    series_list = Scraper.scrape_series(base_url, series_paths)

    Logger.info("[GIndex Sync] Found #{length(series_list)} series to sync")

    {total_series, total_episodes} =
      series_list
      |> Enum.chunk_every(@series_batch_size)
      |> Enum.reduce({0, 0}, &process_batch(provider, &1, &2))

    {:ok, %{series_count: total_series, episodes_count: total_episodes}}
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during series sync: #{inspect(e)}")
      {:error, e}
  end

  def upsert_batch(%Provider{} = provider, series_list) when is_list(series_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    total_episodes =
      Enum.reduce(series_list, 0, fn series_data, acc ->
        case Persistence.upsert_series_content(provider, series_data, now) do
          {:ok, episode_count} -> acc + episode_count
          {:error, _} -> acc
        end
      end)

    {:ok, %{series_count: length(series_list), episodes_count: total_episodes}}
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert series batch: #{inspect(e)}")
      {:error, e}
  end

  defp process_batch(provider, batch, {series_acc, episodes_acc}) do
    case upsert_batch(provider, batch) do
      {:ok, %{series_count: count, episodes_count: episode_count}} ->
        {series_acc + count, episodes_acc + episode_count}

      {:error, _} ->
        {series_acc, episodes_acc}
    end
  end
end
