defmodule Streamix.Iptv.Sync.Series.SeasonsEpisodes do
  @moduledoc """
  Season and episode upserts for detailed series responses.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Season, Series}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Iptv.Sync.Series.Enrichment
  alias Streamix.Repo

  @doc """
  Upserts seasons and episodes for a series from a detailed Xtream response.
  """
  def sync(%Series{} = series, info) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    seasons_data = info["seasons"] || []
    episodes_map = info["episodes"] || %{}

    Enrichment.update_series_from_info(series, info["info"])

    {season_count, inserted_seasons, current_season_nums} =
      upsert_seasons(seasons_data, series.id, now)

    delete_orphaned_seasons(series.id, current_season_nums)

    season_num_to_id =
      Map.new(inserted_seasons, fn %{id: id, season_number: num} -> {num, id} end)

    episode_count =
      Enum.reduce(episodes_map, 0, fn {season_num_str, episodes}, acc ->
        season_num = String.to_integer(season_num_str)
        season_id = season_num_to_id[season_num]
        acc + upsert_episodes(episodes, season_id, series.provider_id, now)
      end)

    {:ok, %{seasons: season_count, episodes: episode_count}}
  end

  defp upsert_seasons(seasons_data, series_id, now) do
    season_attrs_list =
      seasons_data
      |> Enum.uniq_by(fn season -> season["season_number"] end)
      |> Enum.map(&season_attrs(&1, series_id, now))

    {count, inserted_seasons} =
      Repo.insert_all(Season, season_attrs_list,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:series_id, :season_number],
        returning: [:id, :season_number]
      )

    current_season_nums = Enum.map(seasons_data, & &1["season_number"])

    {count, inserted_seasons, current_season_nums}
  end

  defp season_attrs(season, series_id, now) do
    %{
      season_number: season["season_number"],
      name: season["name"],
      cover: season["cover"] || season["cover_big"],
      air_date: Helpers.parse_date(season["air_date"]),
      overview: season["overview"],
      episode_count: season["episode_count"] || 0,
      series_id: series_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp delete_orphaned_seasons(series_id, current_season_nums) do
    Season
    |> where([s], s.series_id == ^series_id)
    |> where([s], s.season_number not in ^current_season_nums)
    |> Repo.delete_all()
  end

  defp upsert_episodes(_episodes, nil, _provider_id, _now), do: 0

  defp upsert_episodes(episodes, season_id, provider_id, now) do
    existing_episode_nums =
      Episode
      |> where(season_id: ^season_id)
      |> select([e], e.episode_num)
      |> Repo.all()
      |> MapSet.new()

    raw_attrs_list = build_episode_attrs(episodes, season_id, now)

    new_attrs =
      Enum.filter(raw_attrs_list, fn attrs ->
        not MapSet.member?(existing_episode_nums, attrs[:episode_num])
      end)

    new_ci_ids = Helpers.pre_create_catalog_items(length(new_attrs), "episode", provider_id, now)
    new_ep_nums = Enum.map(new_attrs, & &1[:episode_num])
    new_ci_map = Enum.zip(new_ep_nums, new_ci_ids) |> Map.new()
    existing_ci_map = fetch_existing_episode_catalog_items(season_id, existing_episode_nums)
    ci_map = Map.merge(existing_ci_map, new_ci_map)

    episode_attrs_list =
      Enum.map(raw_attrs_list, fn attrs ->
        Map.put(attrs, :catalog_item_id, ci_map[attrs[:episode_num]])
      end)

    {count, _} =
      Repo.insert_all(Episode, episode_attrs_list,
        on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
        conflict_target: [:season_id, :episode_num]
      )

    current_episode_nums = Enum.map(episodes, &Helpers.parse_int(&1["episode_num"]))
    delete_orphaned_episodes(season_id, current_episode_nums)

    count
  end

  defp fetch_existing_episode_catalog_items(season_id, existing_episode_nums) do
    if MapSet.size(existing_episode_nums) > 0 do
      Episode
      |> where(season_id: ^season_id)
      |> select([e], {e.episode_num, e.catalog_item_id})
      |> Repo.all()
      |> Map.new()
    else
      %{}
    end
  end

  defp delete_orphaned_episodes(season_id, current_episode_nums) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT catalog_item_id FROM episodes
        WHERE season_id = $1 AND episode_num != ALL($2)
        """,
        [season_id, current_episode_nums]
      )

    orphan_catalog_ids = Enum.map(rows, fn [id] -> id end)

    result =
      Episode
      |> where([e], e.season_id == ^season_id)
      |> where([e], e.episode_num not in ^current_episode_nums)
      |> Repo.delete_all()

    if orphan_catalog_ids != [] do
      Repo.query!("DELETE FROM catalog_items WHERE id = ANY($1)", [orphan_catalog_ids])
    end

    result
  end

  defp build_episode_attrs(episodes, season_id, now) do
    episodes
    |> Enum.uniq_by(fn episode -> Helpers.parse_int(episode["episode_num"]) end)
    |> Enum.map(&episode_attrs(&1, season_id, now))
  end

  defp episode_attrs(episode, season_id, now) do
    %{
      episode_id: Helpers.parse_int(episode["id"]),
      episode_num: Helpers.parse_int(episode["episode_num"]),
      title: episode["title"],
      plot: get_in(episode, ["info", "plot"]),
      cover: get_in(episode, ["info", "cover_big"]) || get_in(episode, ["info", "movie_image"]),
      duration_secs: get_in(episode, ["info", "duration_secs"]),
      container_extension: episode["container_extension"],
      season_id: season_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
