defmodule Streamix.Iptv.Sync.Series do
  @moduledoc """
  Series, season, and episode synchronization from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Provider, Providers, Season, Series, TmdbClient, XtreamClient}
  alias Streamix.Iptv.Sync.{Helpers, Telemetry}
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs series (without details) for a provider.
  """
  def sync_series(%Provider{} = provider) do
    Logger.info("Syncing series for provider #{provider.id}")

    case XtreamClient.get_series(provider.url, provider.username, provider.password) do
      {:ok, series_list} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "series")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Upsert in batches
        {count, all_series_ids} =
          upsert_series_batched(series_list, provider.id, category_lookup, now)

        # Sync genres and credits from the raw stream data
        Helpers.sync_genres_and_credits(
          series_list,
          provider.id,
          Series,
          "series_genres",
          "series_id",
          credits_table: "series_credits",
          stream_id_key: "series_id"
        )

        # Delete orphaned series
        deleted_count = delete_orphaned_series(provider.id, all_series_ids)

        now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

        provider
        |> Provider.sync_changeset(%{series_count: count, series_synced_at: now_utc})
        |> Repo.update()

        Logger.info("Synced #{count} series, removed #{deleted_count} orphaned")
        {:ok, count}

      {:error, reason} ->
        {:error, {:series_sync_failed, reason}}
    end
  end

  @chunk_size 100

  @doc """
  Syncs seasons and episodes for ALL series of a provider.
  Uses streaming with chunked processing to avoid loading all series into memory.
  Each chunk is processed with Task.async_stream for concurrency.
  """
  def sync_all_series_details(%Provider{} = provider) do
    Logger.info("Syncing all series details for provider #{provider.id}")

    # Get total count without loading all records
    total = Repo.aggregate(from(s in Series, where: s.provider_id == ^provider.id), :count)

    Logger.info("Syncing details for #{total} series (this may take a while)...")

    # Emit initial progress
    Telemetry.progress(provider, :details, current: 0, total: total, type: :series)

    # Stream series in chunks to avoid memory issues
    query = from(s in Series, where: s.provider_id == ^provider.id, order_by: s.id)

    results =
      Repo.transaction(
        fn ->
          query
          |> Repo.stream(max_rows: @chunk_size)
          |> Stream.chunk_every(@chunk_size)
          |> Enum.reduce(%{success: 0, failed: 0, episodes: 0, seasons: 0}, fn chunk, acc ->
            chunk_results = process_series_chunk(chunk)
            merged = merge_results(acc, chunk_results)

            # Emit progress after each chunk
            Telemetry.progress(provider, :details,
              current: merged.success + merged.failed,
              total: total,
              type: :series
            )

            merged
          end)
        end,
        timeout: :infinity
      )

    case results do
      {:ok, final_results} ->
        Logger.info(
          "Series details sync completed: #{final_results.success}/#{total} series, " <>
            "#{final_results.seasons} seasons, #{final_results.episodes} episodes"
        )

        {:ok, final_results}

      {:error, reason} ->
        Logger.error("Series details sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_series_chunk(series_list) do
    series_list
    |> Task.async_stream(
      fn series ->
        case sync_series_details(series) do
          {:ok, result} -> {:ok, series.id, result}
          {:error, reason} -> {:error, series.id, reason}
        end
      end,
      max_concurrency: 10,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{success: 0, failed: 0, episodes: 0, seasons: 0}, fn
      {:ok, {:ok, _id, %{seasons: s, episodes: e}}}, acc ->
        %{acc | success: acc.success + 1, seasons: acc.seasons + s, episodes: acc.episodes + e}

      {:ok, {:error, _id, _reason}}, acc ->
        %{acc | failed: acc.failed + 1}

      {:exit, _reason}, acc ->
        %{acc | failed: acc.failed + 1}
    end)
  end

  defp merge_results(acc, chunk_results) do
    %{
      success: acc.success + chunk_results.success,
      failed: acc.failed + chunk_results.failed,
      episodes: acc.episodes + chunk_results.episodes,
      seasons: acc.seasons + chunk_results.seasons
    }
  end

  @doc """
  Syncs seasons and episodes for a specific series.
  Called on-demand when viewing series details.
  Uses UPSERT strategy to preserve episode IDs for watch history references.
  """
  def sync_series_details(%Series{} = series) do
    provider = Providers.get!(series.provider_id)

    case XtreamClient.get_series_info(
           provider.url,
           provider.username,
           provider.password,
           series.series_id
         ) do
      {:ok, info} ->
        sync_seasons_and_episodes(series, info)

      {:error, reason} ->
        {:error, {:series_info_failed, reason}}
    end
  end

  # =============================================================================
  # Series Upsert
  # =============================================================================

  defp upsert_series_batched(series_list, provider_id, category_lookup, now) do
    # Build set of existing series_ids for this provider
    existing_series_ids =
      Series
      |> where(provider_id: ^provider_id)
      |> select([s], s.series_id)
      |> Repo.all()
      |> MapSet.new()

    series_list
    |> Enum.chunk_every(Helpers.batch_size())
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      # Pre-create catalog_items for NEW series
      new_sids =
        batch
        |> Enum.map(& &1["series_id"])
        |> Enum.reject(&MapSet.member?(existing_series_ids, &1))

      new_ci_ids = Helpers.pre_create_catalog_items(length(new_sids), "series", provider_id, now)
      new_ci_map = Enum.zip(new_sids, new_ci_ids) |> Map.new()

      # Get existing catalog_item_ids
      existing_sids =
        batch
        |> Enum.map(& &1["series_id"])
        |> Enum.filter(&MapSet.member?(existing_series_ids, &1))

      existing_ci_map =
        if existing_sids != [] do
          Series
          |> where(provider_id: ^provider_id)
          |> where([s], s.series_id in ^existing_sids)
          |> select([s], {s.series_id, s.catalog_item_id})
          |> Repo.all()
          |> Map.new()
        else
          %{}
        end

      ci_map = Map.merge(existing_ci_map, new_ci_map)

      series_data =
        Enum.map(batch, fn s ->
          attrs = series_attrs(s, provider_id, now)
          Map.put(attrs, :catalog_item_id, ci_map[s["series_id"]])
        end)

      {inserted, returned} =
        Repo.insert_all(Series, series_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
          conflict_target: [:provider_id, :series_id],
          returning: [:id, :series_id, :catalog_item_id]
        )

      # Rebuild category associations via item_categories
      catalog_item_ids = Enum.map(returned, & &1.catalog_item_id) |> Enum.reject(&is_nil/1)
      category_assocs = build_series_category_assocs(batch, returned, category_lookup)
      Helpers.rebuild_category_assocs_diff(catalog_item_ids, category_assocs)

      batch_series_ids = Enum.map(batch, & &1["series_id"])
      {acc_count + inserted, acc_ids ++ batch_series_ids}
    end)
  end

  defp delete_orphaned_series(provider_id, current_series_ids) do
    # FK ordering: item_categories → series → catalog_items.
    # The previous version deleted catalog_items before series, which
    # always failed with a foreign-key violation and aborted the whole
    # cleanup pass — leaving ghost titles forever.

    # 1. item_categories (only references catalog_item_id)
    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE catalog_item_id IN (
        SELECT catalog_item_id FROM series
        WHERE provider_id = $1 AND series_id != ALL($2)
      )
      """,
      [provider_id, current_series_ids]
    )

    # 2. Capture the orphan catalog_item IDs before we lose the link
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT catalog_item_id FROM series
        WHERE provider_id = $1 AND series_id != ALL($2)
        """,
        [provider_id, current_series_ids]
      )

    orphan_catalog_ids = Enum.map(rows, fn [id] -> id end)

    # 3. Delete the orphaned series (cascades to seasons/episodes)
    {count, _} =
      Series
      |> where([s], s.provider_id == ^provider_id)
      |> where([s], s.series_id not in ^current_series_ids)
      |> Repo.delete_all()

    # 4. Now safe to drop the dangling catalog_items
    if orphan_catalog_ids != [] do
      Repo.query!(
        "DELETE FROM catalog_items WHERE id = ANY($1)",
        [orphan_catalog_ids]
      )
    end

    count
  end

  defp series_attrs(series, provider_id, now) do
    %{
      series_id: series["series_id"],
      name: series["name"] || "Unknown",
      title: series["title"],
      year: Helpers.parse_year(series["year"]),
      cover: series["cover"],
      rating: Helpers.parse_decimal(series["rating"]),
      plot: series["plot"],
      youtube_trailer: series["youtube_trailer"],
      tmdb_id: Helpers.to_string_or_nil(series["tmdb_id"]),
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_series_category_assocs(series_list, returned_series, category_lookup) do
    series_to_ci_id =
      Map.new(returned_series, fn entity -> {entity.series_id, entity.catalog_item_id} end)

    series_list
    |> Enum.flat_map(fn series ->
      ci_id = series_to_ci_id[series["series_id"]]
      cat_ext_id = to_string(series["category_id"])
      category_id = category_lookup[cat_ext_id]

      if ci_id && category_id do
        [%{catalog_item_id: ci_id, category_id: category_id}]
      else
        []
      end
    end)
  end

  # =============================================================================
  # Seasons and Episodes
  # =============================================================================

  defp sync_seasons_and_episodes(series, info) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    seasons_data = info["seasons"] || []
    episodes_map = info["episodes"] || %{}

    # Update series with info from detailed response (including tmdb_id)
    update_series_from_info(series, info["info"])

    # Upsert seasons
    {season_count, inserted_seasons, current_season_nums} =
      upsert_seasons(seasons_data, series.id, now)

    # Delete orphaned seasons
    delete_orphaned_seasons(series.id, current_season_nums)

    # Build season_number -> id lookup
    season_num_to_id =
      Map.new(inserted_seasons, fn %{id: id, season_number: num} -> {num, id} end)

    # Upsert episodes for each season
    ep_count =
      episodes_map
      |> Enum.reduce(0, fn {season_num_str, episodes}, acc ->
        season_num = String.to_integer(season_num_str)
        season_id = season_num_to_id[season_num]
        count = upsert_episodes(episodes, season_id, series.provider_id, now)
        acc + count
      end)

    {:ok, %{seasons: season_count, episodes: ep_count}}
  end

  # Update series with additional info from get_series_info response
  defp update_series_from_info(_series, nil), do: :ok

  defp update_series_from_info(series, info) when is_map(info) do
    # First, try to get tmdb_id from provider response, or search TMDB if missing
    tmdb_id = resolve_tmdb_id(series, info)

    attrs =
      %{}
      |> maybe_update(:tmdb_id, tmdb_id, series.tmdb_id)
      |> maybe_update(:plot, info["plot"], series.plot)
      |> maybe_update(:youtube_trailer, info["youtube_trailer"], series.youtube_trailer)

    if map_size(attrs) > 0 do
      series
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()
    else
      :ok
    end
  end

  defp update_series_from_info(_series, _info), do: :ok

  # Try to resolve tmdb_id from provider response, or search TMDB by name
  defp resolve_tmdb_id(series, info) do
    case Helpers.to_string_or_nil(info["tmdb_id"]) do
      nil ->
        # Provider doesn't have tmdb_id, try searching TMDB by name
        search_tmdb_for_series(series.name, series.year)

      "" ->
        search_tmdb_for_series(series.name, series.year)

      id ->
        id
    end
  end

  defp search_tmdb_for_series(name, year) when is_binary(name) do
    opts = if year, do: [year: year], else: []

    case TmdbClient.search_series(name, opts) do
      {:ok, %{"results" => [first | _]}} ->
        # Take the first result's ID
        to_string(first["id"])

      _ ->
        nil
    end
  end

  defp search_tmdb_for_series(_, _), do: nil

  # Only update if new value is present and current value is nil
  defp maybe_update(attrs, _key, nil, _current), do: attrs
  defp maybe_update(attrs, _key, "", _current), do: attrs
  defp maybe_update(attrs, _key, _new, current) when not is_nil(current), do: attrs
  defp maybe_update(attrs, key, new, _current), do: Map.put(attrs, key, new)

  defp upsert_seasons(seasons_data, series_id, now) do
    season_attrs_list =
      seasons_data
      # Deduplicate by season_number to avoid ON CONFLICT errors
      |> Enum.uniq_by(fn s -> s["season_number"] end)
      |> Enum.map(fn s ->
        %{
          season_number: s["season_number"],
          name: s["name"],
          cover: s["cover"] || s["cover_big"],
          air_date: Helpers.parse_date(s["air_date"]),
          overview: s["overview"],
          episode_count: s["episode_count"] || 0,
          series_id: series_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, inserted_seasons} =
      Repo.insert_all(Season, season_attrs_list,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:series_id, :season_number],
        returning: [:id, :season_number]
      )

    current_season_nums = Enum.map(seasons_data, & &1["season_number"])

    {count, inserted_seasons, current_season_nums}
  end

  defp delete_orphaned_seasons(series_id, current_season_nums) do
    Season
    |> where([s], s.series_id == ^series_id)
    |> where([s], s.season_number not in ^current_season_nums)
    |> Repo.delete_all()
  end

  defp upsert_episodes(_episodes, nil, _provider_id, _now), do: 0

  defp upsert_episodes(episodes, season_id, provider_id, now) do
    # Find existing episode_nums for this season
    existing_episode_nums =
      Episode
      |> where(season_id: ^season_id)
      |> select([e], e.episode_num)
      |> Repo.all()
      |> MapSet.new()

    raw_attrs_list = build_episode_attrs(episodes, season_id, now)

    # Pre-create catalog_items for NEW episodes
    new_attrs =
      Enum.filter(raw_attrs_list, fn attrs ->
        not MapSet.member?(existing_episode_nums, attrs[:episode_num])
      end)

    new_ci_ids = Helpers.pre_create_catalog_items(length(new_attrs), "episode", provider_id, now)
    new_ep_nums = Enum.map(new_attrs, & &1[:episode_num])
    new_ci_map = Enum.zip(new_ep_nums, new_ci_ids) |> Map.new()

    # Get existing catalog_item_ids
    existing_ci_map =
      if MapSet.size(existing_episode_nums) > 0 do
        Episode
        |> where(season_id: ^season_id)
        |> select([e], {e.episode_num, e.catalog_item_id})
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

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

    # Delete orphaned episodes
    current_episode_nums = Enum.map(episodes, &Helpers.parse_int(&1["episode_num"]))
    delete_orphaned_episodes(season_id, current_episode_nums)

    count
  end

  defp delete_orphaned_episodes(season_id, current_episode_nums) do
    # FK ordering: capture catalog_item_ids → delete episodes → delete
    # the now-dangling catalog_items. Same shape as
    # `delete_orphaned_series/2` and `Helpers.delete_orphaned_content/3`.
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
    # Deduplicate by episode_num to avoid ON CONFLICT errors
    |> Enum.uniq_by(fn ep -> Helpers.parse_int(ep["episode_num"]) end)
    |> Enum.map(fn ep ->
      %{
        episode_id: Helpers.parse_int(ep["id"]),
        episode_num: Helpers.parse_int(ep["episode_num"]),
        title: ep["title"],
        plot: get_in(ep, ["info", "plot"]),
        cover: get_in(ep, ["info", "cover_big"]) || get_in(ep, ["info", "movie_image"]),
        duration_secs: get_in(ep, ["info", "duration_secs"]),
        container_extension: ep["container_extension"],
        season_id: season_id,
        inserted_at: now,
        updated_at: now
      }
    end)
  end
end
