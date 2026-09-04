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
    now = DateTime.utc_now(:second)

    episodes_map = info["episodes"] || %{}

    # Normalize `season_number` to an integer up front. Panels are
    # inconsistent — some serialize it as 1, others as "1". `insert_all`
    # does not cast, so a string value blows up against the integer column
    # and crashes the whole series sync (and the detail mount). Drop
    # seasons whose number can't be parsed.
    seasons_data =
      (info["seasons"] || [])
      |> Enum.map(&normalize_season_number/1)
      |> Enum.reject(&is_nil/1)

    # Some panels return the episodes grouped by season number while
    # leaving the top-level `seasons` list empty (or omitting a season the
    # `episodes` map still references). Without a matching season row,
    # `season_num_to_id` resolves to nil below and `upsert_episodes/4`
    # silently drops those episodes — leaving the series unplayable. Backfill
    # the missing seasons straight from the episode-map keys.
    seasons_data = ensure_seasons_cover_episode_keys(seasons_data, episodes_map)

    Enrichment.update_series_from_info(series, info["info"])

    {season_count, inserted_seasons, current_season_nums} =
      upsert_seasons(seasons_data, series.id, now)

    delete_orphaned_seasons(series.id, current_season_nums)

    season_num_to_id =
      Map.new(inserted_seasons, fn %{id: id, season_number: num} -> {num, id} end)

    # Some panels return non-numeric keys here ("special", "bonus",
    # localised text). String.to_integer/1 used to crash the whole
    # series sync. Skip what we can't parse and log it so a real
    # convention shift surfaces in logs instead of dataloss.
    episode_count =
      Enum.reduce(episodes_map, 0, fn {season_num_str, episodes}, acc ->
        case Integer.parse(to_string(season_num_str)) do
          {season_num, ""} ->
            season_id = season_num_to_id[season_num]
            acc + upsert_episodes(episodes, season_id, series.provider_id, now)

          _ ->
            require Logger

            Logger.warning(
              "[Sync.SeasonsEpisodes] skipping non-numeric season key " <>
                inspect(season_num_str) <> " for series #{series.id}"
            )

            acc
        end
      end)

    {:ok, %{seasons: season_count, episodes: episode_count}}
  end

  # Builds placeholder season maps for every numeric key in the episodes
  # map that isn't already present in `seasons_data`. Only `season_number`
  # is known here; the remaining columns fall back to their defaults in
  # `season_attrs/3`. Non-numeric keys ("special", "bonus", …) are left
  # out — `sync/2` logs and skips those episodes anyway.
  defp ensure_seasons_cover_episode_keys(seasons_data, episodes_map) do
    existing_nums =
      for season <- seasons_data,
          {num, ""} <- [Integer.parse(to_string(season["season_number"]))],
          into: MapSet.new(),
          do: num

    synthetic =
      for key <- Map.keys(episodes_map),
          {num, ""} <- [Integer.parse(to_string(key))],
          not MapSet.member?(existing_nums, num),
          do: %{"season_number" => num}

    seasons_data ++ synthetic
  end

  defp normalize_season_number(season) do
    case Helpers.parse_int(season["season_number"]) do
      nil -> nil
      num -> Map.put(season, "season_number", num)
    end
  end

  # Explicit replace lists, never `:replace_all_except`. That option builds the
  # SET clause from the *schema*, so any column the payload does not carry is
  # written as `EXCLUDED.col` — which, for a column absent from the INSERT, is
  # the column default. Every sync was therefore nulling the episode columns
  # the xtream payload has no opinion about: `name`, `still_path`, `air_date`,
  # `rating`, `tmdb_id`, `tmdb_enriched` and the gindex fields. It is why 2.730
  # of 2.739 xtream episodes had a null `name`, and why TMDB enrichment could
  # not survive a six-hour sync cycle.
  #
  # These lists are exactly what the upstream payload supplies. Anything else
  # belongs to enrichment and is left alone.
  @season_replace_fields ~w(name cover air_date overview episode_count updated_at)a
  @episode_replace_fields ~w(episode_id title plot cover duration_secs
                             container_extension updated_at)a

  defp upsert_seasons(seasons_data, series_id, now) do
    season_attrs_list =
      seasons_data
      |> Enum.uniq_by(fn season -> season["season_number"] end)
      |> Enum.map(&season_attrs(&1, series_id, now))

    {count, inserted_seasons} =
      Repo.insert_all(Season, season_attrs_list,
        on_conflict: {:replace, @season_replace_fields},
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
      episode_count: Helpers.parse_int(season["episode_count"]) || 0,
      series_id: series_id,
      inserted_at: now,
      updated_at: now
    }
  end

  # An empty upstream season list means `get_series_info` came back thin, not
  # that the series lost every season. `not in ^[]` would drop the WHERE filter
  # and truncate the whole tree, cascading into users' watch progress, so the
  # empty case leaves the stored seasons alone.
  defp delete_orphaned_seasons(_series_id, []), do: {0, nil}

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
        on_conflict: {:replace, @episode_replace_fields},
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

  # Same guard as the seasons above: a season whose payload came back empty
  # keeps its episodes instead of having every catalog_item (and, through the
  # cascade, every episode) deleted.
  defp delete_orphaned_episodes(_season_id, []), do: {:ok, {0, nil}}

  defp delete_orphaned_episodes(season_id, current_episode_nums) do
    # All three steps run in one transaction: a crash between the SELECT
    # and the DELETE used to leak orphaned `catalog_items` rows that the
    # nightly cleanup then had to chase. With the FK now CASCADE-on-delete
    # (see migration 20260603134943), removing the catalog_item row is
    # also what kills the episode row, so we collect IDs first and then
    # let the CASCADE do the rest.
    Repo.transaction(fn ->
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
    end)
  end

  # Dedupe by episode_num before mapping. The on_conflict clause downstream
  # uses (season_id, episode_num) as the conflict target, and Postgres
  # rejects an insert_all batch that hits the same target twice with a
  # `cardinality_violation` — some panels return the same episode object
  # more than once inside the same season payload.
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
      duration_secs: Helpers.parse_int(get_in(episode, ["info", "duration_secs"])),
      container_extension: episode["container_extension"],
      season_id: season_id,
      inserted_at: now,
      updated_at: now
    }
  end
end
