defmodule Streamix.Gindex.Sync.Persistence do
  @moduledoc """
  Translates GIndex series trees into the IPTV ingest contract.

  GIndex owns the upstream shape; the IPTV context owns schemas, catalog item
  allocation, transactions, and conflict handling.
  """

  alias Streamix.Gindex.Sync.Normalizers.{Episode, Season, Series}

  require Logger

  @spec upsert_series_content(map(), map(), DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_series_content(source, data, now, opts \\ [])

  def upsert_series_content(%{provider_id: provider_id}, data, %DateTime{} = now, opts) do
    type_label = Keyword.get(opts, :type_label, "series")
    content_name = data.name

    try do
      content = normalize_content(data)

      case Streamix.Catalog.upsert_gindex_series(provider_id, content, now) do
        {:ok, episode_count} ->
          Logger.debug(
            "[GIndex Sync] Synced #{type_label} '#{content_name}' with #{episode_count} episodes"
          )

          {:ok, episode_count}

        {:error, reason} ->
          log_failure(type_label, content_name, reason)
          {:error, reason}
      end
    rescue
      error ->
        log_failure(type_label, content_name, error)
        {:error, error}
    end
  end

  defp normalize_content(data) do
    %{
      series: Series.attrs(data),
      seasons: Enum.map(data.seasons, &normalize_season/1)
    }
  end

  defp normalize_season(season) do
    %{
      season: Season.attrs(season),
      episodes: Enum.map(season.episodes, &Episode.attrs/1)
    }
  end

  defp log_failure(type_label, content_name, reason) do
    Logger.error(
      "[GIndex Sync] Failed to upsert #{type_label} #{content_name}: #{inspect(reason)}"
    )
  end
end
