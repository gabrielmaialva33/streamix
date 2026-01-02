defmodule Streamix.Iptv.Gindex.Sync do
  @moduledoc """
  Synchronization module for GIndex content.

  Fetches data from GIndex servers and syncs to database using UPSERT strategy.
  Preserves record IDs for favorites/history references.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Gindex.Scraper
  alias Streamix.Iptv.{Episode, Movie, Provider, Season, Series}
  alias Streamix.Repo

  require Logger

  @batch_size 100
  @series_batch_size 10

  @doc """
  Syncs all content (movies and series) from a GIndex provider.

  Returns {:ok, stats} on success or {:error, reason} on failure.
  stats is a map with :movies_count, :series_count, :episodes_count
  """
  def sync_provider(%Provider{provider_type: :gindex} = provider) do
    Logger.info("[GIndex Sync] Starting sync for provider #{provider.id} (#{provider.name})")

    update_status(provider, "syncing")

    base_url = provider.gindex_url || provider.url
    movies_path = get_movies_path(provider)
    series_paths = get_series_paths(provider)

    # Sync movies
    movies_result = sync_movies(provider, base_url, movies_path)

    # Sync series
    series_result = sync_series(provider, base_url, series_paths)

    case {movies_result, series_result} do
      {{:ok, movies_count}, {:ok, series_stats}} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        stats = %{
          movies_count: movies_count,
          series_count: series_stats.series_count,
          episodes_count: series_stats.episodes_count
        }

        provider
        |> Provider.sync_changeset(%{
          sync_status: "completed",
          movies_count: movies_count,
          series_count: series_stats.series_count,
          vod_synced_at: now
        })
        |> Repo.update()

        Logger.info(
          "[GIndex Sync] Completed: #{movies_count} movies, #{series_stats.series_count} series, #{series_stats.episodes_count} episodes synced"
        )

        {:ok, stats}

      {{:error, reason}, _} ->
        update_status(provider, "failed")
        {:error, reason}

      {_, {:error, reason}} ->
        update_status(provider, "failed")
        {:error, reason}
    end
  end

  def sync_provider(%Provider{} = provider) do
    Logger.warning("[GIndex Sync] Provider #{provider.id} is not a GIndex provider")
    {:error, :not_gindex_provider}
  end

  @doc """
  Syncs movies from a specific category path.
  """
  def sync_category(%Provider{} = provider, category_path) do
    base_url = provider.gindex_url || provider.url

    case Scraper.scrape_category(base_url, category_path) do
      {:ok, movies} ->
        upsert_movies(provider, movies)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists available categories in the GIndex.
  """
  def list_categories(%Provider{} = provider, movies_path \\ nil) do
    base_url = provider.gindex_url || provider.url
    path = movies_path || get_movies_path(provider)

    Scraper.list_categories(base_url, path)
  end

  # Private functions

  defp sync_movies(provider, base_url, movies_path) do
    movies =
      Scraper.scrape_movies(base_url, movies_path)
      |> Stream.chunk_every(@batch_size)
      |> Stream.map(fn batch ->
        case upsert_movies(provider, batch) do
          {:ok, count} -> count
          {:error, _} -> 0
        end
      end)
      |> Enum.sum()

    {:ok, movies}
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during sync: #{inspect(e)}")
      {:error, e}
  end

  defp upsert_movies(provider, movies) when is_list(movies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(movies, fn movie ->
        %{
          provider_id: provider.id,
          stream_id: movie.stream_id,
          name: movie.name,
          title: movie.title,
          year: movie.year,
          container_extension: movie.container_extension,
          gindex_path: movie.gindex_path,
          inserted_at: now,
          updated_at: now
        }
      end)

    conflict_opts = [
      on_conflict:
        {:replace, [:name, :title, :year, :container_extension, :gindex_path, :updated_at]},
      conflict_target: [:provider_id, :stream_id]
    ]

    case Repo.insert_all(Movie, entries, conflict_opts) do
      {count, _} ->
        Logger.debug("[GIndex Sync] Upserted #{count} movies")
        {:ok, count}
    end
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert movies: #{inspect(e)}")
      {:error, e}
  end

  defp update_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end

  defp get_movies_path(provider) do
    case provider.gindex_drives do
      %{"movies_path" => path} when is_binary(path) -> path
      %{"movies" => path} when is_binary(path) -> path
      _ -> "/1:/Filmes/"
    end
  end

  defp get_series_paths(provider) do
    case provider.gindex_drives do
      %{"series_paths" => paths} when is_list(paths) -> paths
      %{"series_path" => path} when is_binary(path) -> [path]
      _ -> ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]
    end
  end

  # =============================================================================
  # Series Sync Functions
  # =============================================================================

  @doc """
  Syncs series from GIndex provider.

  Returns {:ok, stats} with series_count and episodes_count.
  """
  def sync_series(provider, base_url, series_paths) do
    Logger.info("[GIndex Sync] Starting series sync from #{length(series_paths)} paths")

    series_list = Scraper.scrape_series(base_url, series_paths)

    Logger.info("[GIndex Sync] Found #{length(series_list)} series to sync")

    # Process series in batches
    {total_series, total_episodes} =
      series_list
      |> Enum.chunk_every(@series_batch_size)
      |> Enum.reduce({0, 0}, fn batch, {series_acc, episodes_acc} ->
        case upsert_series_batch(provider, batch) do
          {:ok, %{series_count: s, episodes_count: e}} ->
            {series_acc + s, episodes_acc + e}

          {:error, _} ->
            {series_acc, episodes_acc}
        end
      end)

    {:ok, %{series_count: total_series, episodes_count: total_episodes}}
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during series sync: #{inspect(e)}")
      {:error, e}
  end

  defp upsert_series_batch(provider, series_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    total_episodes =
      Enum.reduce(series_list, 0, fn series_data, acc ->
        case upsert_single_series(provider, series_data, now) do
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

  defp upsert_single_series(provider, series_data, now) do
    # Upsert the series
    series_attrs = %{
      provider_id: provider.id,
      series_id: series_data.series_id,
      name: series_data.name,
      title: series_data.title,
      year: series_data.year,
      gindex_path: series_data.gindex_path,
      season_count: series_data.season_count,
      episode_count: series_data.episode_count,
      inserted_at: now,
      updated_at: now
    }

    # First try to find existing series
    existing_series =
      from(s in Series,
        where: s.provider_id == ^provider.id and s.series_id == ^series_data.series_id
      )
      |> Repo.one()

    series =
      case existing_series do
        nil ->
          # Insert new series
          %Series{}
          |> Series.changeset(series_attrs)
          |> Repo.insert!()

        series ->
          # Update existing series
          series
          |> Series.changeset(series_attrs)
          |> Repo.update!()
      end

    # Sync seasons and episodes
    episode_count = sync_series_seasons(series, series_data.seasons, now)

    Logger.debug("[GIndex Sync] Synced series '#{series.name}' with #{episode_count} episodes")

    {:ok, episode_count}
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert series #{series_data.name}: #{inspect(e)}")
      {:error, e}
  end

  defp sync_series_seasons(series, seasons_data, now) do
    Enum.reduce(seasons_data, 0, fn season_data, episode_acc ->
      season = upsert_season(series, season_data, now)
      episodes_count = upsert_episodes(season, season_data.episodes, now)
      episode_acc + episodes_count
    end)
  end

  defp upsert_season(series, season_data, now) do
    # Find or create season
    existing_season =
      from(s in Season,
        where: s.series_id == ^series.id and s.season_number == ^season_data.season_number
      )
      |> Repo.one()

    season_attrs = %{
      series_id: series.id,
      season_number: season_data.season_number,
      name: season_data.name || "Season #{season_data.season_number}",
      episode_count: season_data.episode_count
    }

    case existing_season do
      nil ->
        %Season{}
        |> Season.changeset(Map.merge(season_attrs, %{inserted_at: now, updated_at: now}))
        |> Repo.insert!()

      season ->
        season
        |> Season.changeset(Map.put(season_attrs, :updated_at, now))
        |> Repo.update!()
    end
  end

  defp upsert_episodes(season, episodes_data, now) do
    # Build episode entries
    entries =
      Enum.map(episodes_data, fn ep ->
        %{
          season_id: season.id,
          episode_id: ep.episode_id,
          episode_num: ep.episode_num,
          title: ep.title,
          name: ep.name,
          container_extension: ep.container_extension,
          gindex_path: ep.gindex_path,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Upsert all episodes
    conflict_opts = [
      on_conflict: {:replace, [:title, :name, :container_extension, :gindex_path, :updated_at]},
      conflict_target: [:season_id, :episode_id]
    ]

    {count, _} = Repo.insert_all(Episode, entries, conflict_opts)
    count
  end
end
