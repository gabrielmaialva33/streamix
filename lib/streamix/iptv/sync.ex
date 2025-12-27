defmodule Streamix.Iptv.Sync do
  @moduledoc """
  Synchronization module for IPTV content.
  Fetches data from Xtream Codes API and syncs to database using UPSERT strategy.

  Uses INSERT ... ON CONFLICT UPDATE to preserve record IDs, which is critical
  for maintaining favorites and watch history references across syncs.
  """

  import Ecto.Query, warn: false

  alias Streamix.Repo

  alias Streamix.Iptv.{
    Category,
    Episode,
    Favorite,
    LiveChannel,
    Movie,
    Provider,
    Season,
    Series,
    TmdbClient,
    WatchHistory,
    XtreamClient
  }

  require Logger

  @batch_size 500

  # =============================================================================
  # Full Sync
  # =============================================================================

  @doc """
  Syncs all content from a provider (categories, live, vod, series).
  Uses UPSERT strategy to preserve record IDs for favorites/history references.

  ## Options

    * `:series_details` - How to handle series details (seasons/episodes):
      - `:skip` (default) - Don't sync series details
      - `:immediate` - Sync all series details immediately (slow, blocks)
      - `:enqueue` - Enqueue background jobs to sync in batches (recommended for production)

    * `:batch_size` - When using `:enqueue`, the number of series per batch job (default: 50)

  """
  def sync_all(%Provider{} = provider, opts \\ []) do
    Logger.info("Starting full sync for provider #{provider.id}")

    update_status(provider, "syncing")

    with {:ok, _} <- sync_categories(provider),
         {:ok, live_count} <- sync_live_channels(provider),
         {:ok, vod_count} <- sync_movies(provider),
         {:ok, series_count} <- sync_series(provider),
         {:ok, details} <- handle_series_details(provider, opts) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      provider
      |> Provider.sync_changeset(%{
        sync_status: "completed",
        live_channels_count: live_count,
        movies_count: vod_count,
        series_count: series_count,
        live_synced_at: now,
        vod_synced_at: now,
        series_synced_at: now
      })
      |> Repo.update()

      # Clean up orphaned favorites and watch history
      cleanup_orphaned_user_data()

      Logger.info(
        "Full sync completed: #{live_count} live, #{vod_count} movies, #{series_count} series"
      )

      {:ok, %{live: live_count, movies: vod_count, series: series_count, details: details}}
    else
      {:error, reason} ->
        update_status(provider, "failed")
        {:error, reason}
    end
  end

  defp handle_series_details(provider, opts) do
    case Keyword.get(opts, :series_details, :skip) do
      :skip ->
        {:ok, nil}

      :immediate ->
        sync_all_series_details(provider)

      :enqueue ->
        alias Streamix.Workers.SyncSeriesDetailsWorker
        batch_size = Keyword.get(opts, :batch_size, 50)

        case SyncSeriesDetailsWorker.enqueue_all_for_provider(provider.id, batch_size: batch_size) do
          {:ok, job_count} ->
            Logger.info("Enqueued #{job_count} jobs for series details sync")
            {:ok, %{enqueued_jobs: job_count}}

          error ->
            error
        end

      # Backwards compatibility
      true ->
        sync_all_series_details(provider)

      false ->
        {:ok, nil}
    end
  end

  # =============================================================================
  # Categories
  # =============================================================================

  def sync_categories(%Provider{} = provider) do
    Logger.info("Syncing categories for provider #{provider.id}")

    with {:ok, live_cats} <-
           XtreamClient.get_live_categories(provider.url, provider.username, provider.password),
         {:ok, vod_cats} <-
           XtreamClient.get_vod_categories(provider.url, provider.username, provider.password),
         {:ok, series_cats} <-
           XtreamClient.get_series_categories(provider.url, provider.username, provider.password) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      all_categories =
        Enum.map(live_cats, &category_attrs(&1, "live", provider.id, now)) ++
          Enum.map(vod_cats, &category_attrs(&1, "vod", provider.id, now)) ++
          Enum.map(series_cats, &category_attrs(&1, "series", provider.id, now))

      # Upsert categories
      {count, _} =
        Repo.insert_all(Category, all_categories,
          on_conflict: {:replace, [:name, :updated_at]},
          conflict_target: [:provider_id, :external_id, :type]
        )

      # Delete orphaned categories (no longer in API response)
      current_external_ids = Enum.map(all_categories, & &1.external_id)

      deleted_count = delete_orphaned_categories(provider.id, current_external_ids)

      Logger.info("Synced #{count} categories, removed #{deleted_count} orphaned")
      {:ok, count}
    end
  end

  defp delete_orphaned_categories(provider_id, current_external_ids) do
    {count, _} =
      Category
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.external_id not in ^current_external_ids)
      |> Repo.delete_all()

    count
  end

  defp category_attrs(cat, type, provider_id, now) do
    %{
      external_id: to_string(cat["category_id"]),
      name: cat["category_name"] || "Unknown",
      type: type,
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  # =============================================================================
  # Live Channels
  # =============================================================================

  def sync_live_channels(%Provider{} = provider) do
    Logger.info("Syncing live channels for provider #{provider.id}")

    case XtreamClient.get_live_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = build_category_lookup(provider.id, "live")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Upsert in batches and collect all stream_ids
        {count, all_stream_ids} =
          upsert_live_channels_batched(streams, provider.id, category_lookup, now)

        # Delete orphaned channels
        deleted_count = delete_orphaned_live_channels(provider.id, all_stream_ids)

        now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

        provider
        |> Provider.sync_changeset(%{live_channels_count: count, live_synced_at: now_utc})
        |> Repo.update()

        Logger.info("Synced #{count} live channels, removed #{deleted_count} orphaned")
        {:ok, count}

      {:error, reason} ->
        {:error, {:live_sync_failed, reason}}
    end
  end

  defp upsert_live_channels_batched(streams, provider_id, category_lookup, now) do
    streams
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      channels_data = Enum.map(batch, &live_channel_attrs(&1, provider_id, now))

      {inserted, returned} =
        Repo.insert_all(LiveChannel, channels_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:provider_id, :stream_id],
          returning: [:id, :stream_id]
        )

      # Rebuild category associations for this batch
      rebuild_live_category_assocs(batch, returned, category_lookup)

      batch_stream_ids = Enum.map(batch, & &1["stream_id"])
      {acc_count + inserted, acc_ids ++ batch_stream_ids}
    end)
  end

  defp rebuild_live_category_assocs(streams, returned_channels, category_lookup) do
    channel_ids = Enum.map(returned_channels, & &1.id)

    # Delete existing associations for these channels
    Repo.query!(
      "DELETE FROM live_channel_categories WHERE live_channel_id = ANY($1)",
      [channel_ids]
    )

    # Build new associations
    category_assocs = build_live_category_assocs(streams, returned_channels, category_lookup)

    unless Enum.empty?(category_assocs) do
      Repo.insert_all("live_channel_categories", category_assocs)
    end
  end

  defp delete_orphaned_live_channels(provider_id, current_stream_ids) do
    # First delete category associations for orphaned channels
    Repo.query!(
      """
      DELETE FROM live_channel_categories
      WHERE live_channel_id IN (
        SELECT id FROM live_channels
        WHERE provider_id = $1 AND stream_id != ALL($2)
      )
      """,
      [provider_id, current_stream_ids]
    )

    # Then delete the orphaned channels
    {count, _} =
      LiveChannel
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.stream_id not in ^current_stream_ids)
      |> Repo.delete_all()

    count
  end

  defp live_channel_attrs(stream, provider_id, now) do
    %{
      stream_id: stream["stream_id"],
      name: stream["name"] || "Unknown",
      stream_icon: stream["stream_icon"],
      epg_channel_id: stream["epg_channel_id"],
      tv_archive: stream["tv_archive"] == 1,
      tv_archive_duration: stream["tv_archive_duration"],
      direct_source: stream["direct_source"],
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_live_category_assocs(streams, returned_channels, category_lookup) do
    stream_to_db_id =
      Map.new(returned_channels, fn %{id: id, stream_id: stream_id} -> {stream_id, id} end)

    streams
    |> Enum.flat_map(fn stream ->
      channel_id = stream_to_db_id[stream["stream_id"]]
      cat_ext_id = to_string(stream["category_id"])
      category_id = category_lookup[cat_ext_id]

      if channel_id && category_id do
        [%{live_channel_id: channel_id, category_id: category_id}]
      else
        []
      end
    end)
  end

  # =============================================================================
  # Movies (VOD)
  # =============================================================================

  def sync_movies(%Provider{} = provider) do
    Logger.info("Syncing movies for provider #{provider.id}")

    case XtreamClient.get_vod_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = build_category_lookup(provider.id, "vod")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Upsert in batches
        {count, all_stream_ids} =
          upsert_movies_batched(streams, provider.id, category_lookup, now)

        # Delete orphaned movies
        deleted_count = delete_orphaned_movies(provider.id, all_stream_ids)

        now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

        provider
        |> Provider.sync_changeset(%{movies_count: count, vod_synced_at: now_utc})
        |> Repo.update()

        Logger.info("Synced #{count} movies, removed #{deleted_count} orphaned")
        {:ok, count}

      {:error, reason} ->
        {:error, {:vod_sync_failed, reason}}
    end
  end

  defp upsert_movies_batched(streams, provider_id, category_lookup, now) do
    streams
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce({0, []}, fn batch, {acc_count, acc_ids} ->
      movies_data = Enum.map(batch, &movie_attrs(&1, provider_id, now))

      {inserted, returned} =
        Repo.insert_all(Movie, movies_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:provider_id, :stream_id],
          returning: [:id, :stream_id]
        )

      # Rebuild category associations for this batch
      rebuild_movie_category_assocs(batch, returned, category_lookup)

      batch_stream_ids = Enum.map(batch, & &1["stream_id"])
      {acc_count + inserted, acc_ids ++ batch_stream_ids}
    end)
  end

  defp rebuild_movie_category_assocs(streams, returned_movies, category_lookup) do
    movie_ids = Enum.map(returned_movies, & &1.id)

    # Delete existing associations for these movies
    Repo.query!(
      "DELETE FROM movie_categories WHERE movie_id = ANY($1)",
      [movie_ids]
    )

    # Build new associations
    category_assocs = build_movie_category_assocs(streams, returned_movies, category_lookup)

    unless Enum.empty?(category_assocs) do
      Repo.insert_all("movie_categories", category_assocs)
    end
  end

  defp delete_orphaned_movies(provider_id, current_stream_ids) do
    # First delete category associations for orphaned movies
    Repo.query!(
      """
      DELETE FROM movie_categories
      WHERE movie_id IN (
        SELECT id FROM movies
        WHERE provider_id = $1 AND stream_id != ALL($2)
      )
      """,
      [provider_id, current_stream_ids]
    )

    # Then delete the orphaned movies
    {count, _} =
      Movie
      |> where([m], m.provider_id == ^provider_id)
      |> where([m], m.stream_id not in ^current_stream_ids)
      |> Repo.delete_all()

    count
  end

  defp movie_attrs(stream, provider_id, now) do
    %{
      stream_id: stream["stream_id"],
      name: stream["name"] || "Unknown",
      title: stream["title"],
      year: parse_year(stream["year"]),
      stream_icon: stream["stream_icon"],
      rating: parse_decimal(stream["rating"]),
      rating_5based: parse_decimal(stream["rating_5based"]),
      genre: stream["genre"],
      cast: stream["cast"],
      director: stream["director"],
      plot: stream["plot"],
      container_extension: stream["container_extension"],
      duration_secs: stream["duration_secs"],
      duration: stream["duration"],
      tmdb_id: to_string_or_nil(stream["tmdb_id"]),
      imdb_id: to_string_or_nil(stream["imdb_id"]),
      backdrop_path: normalize_backdrop(stream["backdrop_path"]),
      youtube_trailer: stream["youtube_trailer"],
      provider_id: provider_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_movie_category_assocs(streams, returned_movies, category_lookup) do
    stream_to_db_id =
      Map.new(returned_movies, fn %{id: id, stream_id: stream_id} -> {stream_id, id} end)

    streams
    |> Enum.flat_map(fn stream ->
      movie_id = stream_to_db_id[stream["stream_id"]]
      cat_ext_id = to_string(stream["category_id"])
      category_id = category_lookup[cat_ext_id]

      if movie_id && category_id do
        [%{movie_id: movie_id, category_id: category_id}]
      else
        []
      end
    end)
  end

  # =============================================================================
  # Series
  # =============================================================================

  def sync_series(%Provider{} = provider) do
    Logger.info("Syncing series for provider #{provider.id}")

    case XtreamClient.get_series(provider.url, provider.username, provider.password) do
      {:ok, series_list} ->
        category_lookup = build_category_lookup(provider.id, "series")
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

  defp upsert_series_batched(series_list, provider_id, category_lookup, now) do
    series_list
    |> Enum.chunk_every(@batch_size)
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

    # Delete existing associations for these series
    Repo.query!(
      "DELETE FROM series_categories WHERE series_id = ANY($1)",
      [series_ids]
    )

    # Build new associations
    category_assocs = build_series_category_assocs(series_list, returned_series, category_lookup)

    unless Enum.empty?(category_assocs) do
      Repo.insert_all("series_categories", category_assocs)
    end
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
      year: parse_year(series["year"]),
      cover: series["cover"],
      rating: parse_decimal(series["rating"]),
      rating_5based: parse_decimal(series["rating_5based"]),
      genre: series["genre"],
      cast: series["cast"],
      director: series["director"],
      plot: series["plot"],
      backdrop_path: normalize_backdrop(series["backdrop_path"]),
      youtube_trailer: series["youtube_trailer"],
      tmdb_id: to_string_or_nil(series["tmdb_id"]),
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

  @doc """
  Syncs seasons and episodes for ALL series of a provider.
  Uses Task.async_stream with concurrency for performance.
  """
  def sync_all_series_details(%Provider{} = provider) do
    Logger.info("Syncing all series details for provider #{provider.id}")

    series_list = Repo.all(from s in Series, where: s.provider_id == ^provider.id)
    total = length(series_list)

    Logger.info("Syncing details for #{total} series (this may take a while)...")

    results =
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

    Logger.info(
      "Series details sync completed: #{results.success}/#{total} series, " <>
        "#{results.seasons} seasons, #{results.episodes} episodes"
    )

    {:ok, results}
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
      |> maybe_update(:backdrop_path, normalize_backdrop(info["backdrop_path"]), series.backdrop_path)

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
    case to_string_or_nil(info["tmdb_id"]) do
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
          air_date: parse_date(s["air_date"]),
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
    current_episode_nums = Enum.map(episodes, &parse_int(&1["episode_num"]))
    delete_orphaned_episodes(season_id, current_episode_nums)

    count
  end

  defp delete_orphaned_episodes(season_id, current_episode_nums) do
    Episode
    |> where([e], e.season_id == ^season_id)
    |> where([e], e.episode_num not in ^current_episode_nums)
    |> Repo.delete_all()
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp build_episode_attrs(episodes, season_id, now) do
    episodes
    # Deduplicate by episode_num to avoid ON CONFLICT errors
    |> Enum.uniq_by(fn ep -> parse_int(ep["episode_num"]) end)
    |> Enum.map(fn ep ->
      %{
        episode_id: parse_int(ep["id"]),
        episode_num: parse_int(ep["episode_num"]),
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

  defp build_category_lookup(provider_id, type) do
    Category
    |> where(provider_id: ^provider_id, type: ^type)
    |> select([c], {c.external_id, c.id})
    |> Repo.all()
    |> Map.new()
  end

  defp update_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end

  defp parse_year(nil), do: nil
  defp parse_year(year) when is_integer(year), do: year

  defp parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {y, _} -> y
      :error -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)

  defp parse_decimal(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> Decimal.from_float(f)
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp normalize_backdrop(nil), do: nil
  defp normalize_backdrop(list) when is_list(list), do: list
  defp normalize_backdrop(str) when is_binary(str), do: [str]

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  # =============================================================================
  # Orphaned User Data Cleanup
  # =============================================================================

  @doc """
  Cleans up favorites and watch history that reference deleted content.
  Called after sync to remove orphaned user data.
  """
  def cleanup_orphaned_user_data do
    Logger.info("Cleaning up orphaned favorites and watch history")

    # Clean up favorites
    {fav_live, _} = cleanup_orphaned_favorites("live_channel", LiveChannel)
    {fav_movie, _} = cleanup_orphaned_favorites("movie", Movie)
    {fav_series, _} = cleanup_orphaned_favorites("series", Series)

    # Clean up watch history
    {hist_live, _} = cleanup_orphaned_watch_history("live_channel", LiveChannel)
    {hist_movie, _} = cleanup_orphaned_watch_history("movie", Movie)
    {hist_episode, _} = cleanup_orphaned_watch_history("episode", Episode)

    total_fav = fav_live + fav_movie + fav_series
    total_hist = hist_live + hist_movie + hist_episode

    if total_fav > 0 or total_hist > 0 do
      Logger.info(
        "Removed #{total_fav} orphaned favorites, #{total_hist} orphaned history entries"
      )
    end

    {:ok, %{favorites: total_fav, watch_history: total_hist}}
  end

  defp cleanup_orphaned_favorites(content_type, schema) do
    Favorite
    |> where([f], f.content_type == ^content_type)
    |> where([f], f.content_id not in subquery(from(s in schema, select: s.id)))
    |> Repo.delete_all()
  end

  defp cleanup_orphaned_watch_history(content_type, schema) do
    WatchHistory
    |> where([w], w.content_type == ^content_type)
    |> where([w], w.content_id not in subquery(from(s in schema, select: s.id)))
    |> Repo.delete_all()
  end
end
