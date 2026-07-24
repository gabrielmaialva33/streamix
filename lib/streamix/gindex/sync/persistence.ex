defmodule Streamix.Gindex.Sync.Persistence do
  @moduledoc """
  Shared persistence for GIndex series/anime seasons and episodes.
  """

  import Ecto.Query, warn: false

  alias Streamix.Gindex.Sync.Normalizers
  alias Streamix.Iptv.{CatalogItem, Episode, Provider, Season, Series}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  def upsert_series_content(%Provider{} = provider, data, now, opts \\ []) do
    type_label = Keyword.get(opts, :type_label, "series")
    content_name = data.name

    try do
      series = upsert_series(provider, data)
      episode_count = sync_seasons(series, data.seasons, provider.id, now)

      Logger.debug(
        "[GIndex Sync] Synced #{type_label} '#{series.name}' with #{episode_count} episodes"
      )

      {:ok, episode_count}
    rescue
      e ->
        Logger.error(
          "[GIndex Sync] Failed to upsert #{type_label} #{content_name}: #{inspect(e)}"
        )

        {:error, e}
    end
  end

  defp upsert_series(provider, data) do
    attrs = Normalizers.Series.attrs(data, provider)

    case get_existing_series(provider.id, data.series_id) do
      nil ->
        {:ok, catalog_item} =
          Repo.insert(%CatalogItem{content_type: "series", provider_id: provider.id})

        %Series{}
        |> Series.changeset(Map.put(attrs, :catalog_item_id, catalog_item.id))
        |> Repo.insert!()

      series ->
        series
        |> Series.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp get_existing_series(provider_id, series_id) do
    from(s in Series, where: s.provider_id == ^provider_id and s.series_id == ^series_id)
    |> Repo.one()
  end

  defp sync_seasons(series, seasons_data, provider_id, now) do
    Enum.reduce(seasons_data, 0, fn season_data, episode_acc ->
      season = upsert_season(series, season_data, now)
      episode_acc + upsert_episodes(season, season_data.episodes, provider_id, now)
    end)
  end

  defp upsert_season(series, season_data, now) do
    attrs = Normalizers.Season.attrs(series, season_data)

    case get_existing_season(series.id, season_data.season_number) do
      nil ->
        %Season{}
        |> Season.changeset(Map.merge(attrs, %{inserted_at: now, updated_at: now}))
        |> Repo.insert!()

      season ->
        season
        |> Season.changeset(Map.put(attrs, :updated_at, now))
        |> Repo.update!()
    end
  end

  defp get_existing_season(series_id, season_number) do
    from(s in Season, where: s.series_id == ^series_id and s.season_number == ^season_number)
    |> Repo.one()
  end

  defp upsert_episodes(season, episodes_data, provider_id, now) do
    episodes_data = Enum.uniq_by(episodes_data, & &1.episode_num)
    existing = existing_episode_catalog_items(season.id)

    new_episodes =
      Enum.reject(episodes_data, fn episode ->
        Map.has_key?(existing.by_id, episode.episode_id) or
          Map.has_key?(existing.by_num, episode.episode_num)
      end)

    new_ci_ids =
      Helpers.pre_create_catalog_items(length(new_episodes), "episode", provider_id, now)

    new_ci_map =
      new_episodes
      |> Enum.map(&episode_key/1)
      |> Enum.zip(new_ci_ids)
      |> Map.new()

    entries =
      Enum.map(episodes_data, fn episode ->
        catalog_item_id =
          existing.by_id[episode.episode_id] ||
            existing.by_num[episode.episode_num] ||
            new_ci_map[episode_key(episode)]

        Normalizers.Episode.attrs(episode, season, catalog_item_id, now)
      end)

    conflict_opts = [
      on_conflict:
        {:replace, [:episode_id, :title, :name, :container_extension, :gindex_path, :updated_at]},
      conflict_target: [:season_id, :episode_num]
    ]

    case entries do
      [] ->
        0

      _ ->
        {count, _} = Repo.insert_all(Episode, entries, conflict_opts)
        count
    end
  end

  defp existing_episode_catalog_items(season_id) do
    rows =
      Episode
      |> where(season_id: ^season_id)
      |> select([e], {e.episode_id, e.episode_num, e.catalog_item_id})
      |> Repo.all()

    %{
      by_id: Map.new(rows, fn {episode_id, _episode_num, ci_id} -> {episode_id, ci_id} end),
      by_num: Map.new(rows, fn {_episode_id, episode_num, ci_id} -> {episode_num, ci_id} end)
    }
  end

  defp episode_key(episode), do: {episode.episode_id, episode.episode_num}
end
