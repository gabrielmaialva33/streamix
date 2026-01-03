defmodule Streamix.Iptv.Sync.Series do
  @moduledoc """
  Series, season, and episode synchronization from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Provider, Season, Series, TmdbClient, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
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
            merge_results(acc, chunk_results)
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
    provider = Repo.get!(Provider, series.provider_id)

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
    series_list
    |> Enum.chunk_every(Helpers.batch_size())
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      series_data = Enum.map(batch, &series_attrs(&1, provider_id, now))

      {inserted, returned} =
        Repo.insert_all(Series, series_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at, :season_count, :episode_count]},
          conflict_target: [:provider_id, :series_id],
          returning: [:id, :series_id]
        )

      # Rebuild category associations for this batch
      rebuild_series_category_assocs(batch, returned, category_lookup)

      batch_series_ids = Enum.map(batch, & &1["series_id"])
      {acc_count + inserted, acc_ids ++ batch_series_ids}
    end)
  end

  defp rebuild_series_category_assocs(series_list, returned_series, category_lookup) do
    series_ids = Enum.map(returned_series, & &1.id)
    category_assocs = build_series_category_assocs(series_list, returned_series, category_lookup)

    # Use diff-based rebuild to avoid WAL bloat and visibility gaps
    Helpers.rebuild_category_assocs_diff(
      "series_categories",
      "series_id",
      "category_id",
      series_ids,
      category_assocs
    )
  end

  defp delete_orphaned_series(provider_id, current_series_ids) do
    # First delete category associations for orphaned series
    Repo.query!(
      """
      DELETE FROM series_categories
      WHERE series_id IN (
        SELECT id FROM series
        WHERE provider_id = $1 AND series_id != ALL($2)
      )
      """,
      [provider_id, current_series_ids]
    )

    # Then delete the orphaned series (cascades to seasons/episodes)
    {count, _} =
      Series
      |> where([s], s.provider_id == ^provider_id)
      |> where([s], s.series_id not in ^current_series_ids)
      |> Repo.delete_all()

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
      rating_5based: Helpers.parse_decimal(series["rating_5based"]),
      genre: series["genre"],
      cast: series["cast"],
      director: series["director"],
      plot: series["plot"],
      backdrop_path: Helpers.normalize_backdrop(series["backdrop_path"]),
      youtube_trailer: series["youtube_trailer"],
      tmdb_id: Helpers.to_string_or_nil(series["tmdb_id"]),
      season_count: 0,
      episode_count: 0,
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_series_category_assocs(series_list, returned_series, category_lookup) do
    series_to_db_id =
      Map.new(returned_series, fn %{id: id, series_id: series_id} -> {series_id, id} end)

    series_list
    |> Enum.flat_map(fn series ->
      db_series_id = series_to_db_id[series["series_id"]]
      cat_ext_id = to_string(series["category_id"])
      category_id = category_lookup[cat_ext_id]

      if db_series_id && category_id do
        [%{series_id: db_series_id, category_id: category_id}]
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
        count = upsert_episodes(episodes, season_id, now)
        acc + count
      end)

    # Update series counts
    series
    |> Ecto.Changeset.change(%{season_count: season_count, episode_count: ep_count})
    |> Repo.update()

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
      |> maybe_update(:cast, info["cast"], series.cast)
      |> maybe_update(:director, info["director"], series.director)
      |> maybe_update(:genre, info["genre"], series.genre)
      |> maybe_update(:youtube_trailer, info["youtube_trailer"], series.youtube_trailer)
      |> maybe_update(
        :backdrop_path,
        Helpers.normalize_backdrop(info["backdrop_path"]),
        series.backdrop_path
      )

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

  defp upsert_episodes(_episodes, nil, _now), do: 0

  defp upsert_episodes(episodes, season_id, now) do
    episode_attrs_list = build_episode_attrs(episodes, season_id, now)

    {count, _} =
      Repo.insert_all(Episode, episode_attrs_list,
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:season_id, :episode_num]
      )

    # Delete orphaned episodes
    current_episode_nums = Enum.map(episodes, &Helpers.parse_int(&1["episode_num"]))
    delete_orphaned_episodes(season_id, current_episode_nums)

    count
  end

  defp delete_orphaned_episodes(season_id, current_episode_nums) do
    Episode
    |> where([e], e.season_id == ^season_id)
    |> where([e], e.episode_num not in ^current_episode_nums)
    |> Repo.delete_all()
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
        duration: get_in(ep, ["info", "duration"]),
        container_extension: ep["container_extension"],
        season_id: season_id,
        inserted_at: now,
        updated_at: now
      }
    end)
  end
end
