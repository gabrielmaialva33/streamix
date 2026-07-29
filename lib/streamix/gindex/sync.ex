defmodule Streamix.Gindex.Sync do
  @moduledoc """
  Public facade for GIndex provider synchronization.

  Fetches data from GIndex servers and syncs to the database using an UPSERT
  strategy that preserves record IDs for favorites/history references.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.{Animes, Movies, Paths, Series}
  alias Streamix.Iptv.{Provider, Providers}
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs all content (movies, series, and animes) from a GIndex provider.

  Returns `{:ok, stats}` on success or `{:error, reason}` on failure.
  """
  def sync_provider(%Provider{provider_type: :gindex} = provider) do
    Logger.info("[GIndex Sync] Starting sync for provider #{provider.id} (#{provider.name})")

    update_status(provider, "syncing")

    base_url = provider.gindex_url || provider.url
    movies_result = Movies.sync(provider, base_url, Paths.movies_path(provider))
    series_result = Series.sync(provider, base_url, Paths.series_paths(provider))
    animes_result = Animes.sync(provider, base_url, Paths.animes_path(provider))

    finalize_provider_sync(provider, movies_result, series_result, animes_result)
  end

  def sync_provider(%Provider{} = provider) do
    Logger.warning("[GIndex Sync] Provider #{provider.id} is not a GIndex provider")
    {:error, :not_gindex_provider}
  end

  @doc """
  Syncs movies from a specific category path.
  """
  def sync_category(%Provider{} = provider, category_path) do
    Movies.sync_category(provider, provider.gindex_url || provider.url, category_path)
  end

  @doc """
  Lists available categories in the GIndex.
  """
  def list_categories(%Provider{} = provider, movies_path \\ nil) do
    base_url = provider.gindex_url || provider.url
    path = movies_path || Paths.movies_path(provider)

    Scraper.list_categories(base_url, path)
  end

  @doc """
  Syncs a single root path for a given kind.
  """
  @spec sync_kind(Provider.t(), String.t(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_kind(provider, base_url, path, kind, opts \\ [])

  def sync_kind(%Provider{} = provider, base_url, path, :movies, _opts) do
    case Movies.sync(provider, base_url, path) do
      {:ok, count} -> {:ok, %{movies_count: count}}
      error -> error
    end
  end

  def sync_kind(%Provider{} = provider, base_url, path, :series, opts) do
    Series.sync(provider, base_url, [path], opts)
  end

  def sync_kind(%Provider{} = provider, base_url, path, :animes, _opts) do
    Animes.sync(provider, base_url, path)
  end

  @doc """
  Syncs a batch of movies to the database.
  Used by Broadway pipeline for distributed sync.
  """
  def sync_movies_batch(%Provider{} = provider, movies) when is_list(movies) do
    Logger.info("[GIndex Sync] Syncing batch of #{length(movies)} movies")
    Movies.upsert_batch(provider, movies)
  end

  @doc """
  Syncs a batch of series to the database.
  Used by Broadway pipeline for distributed sync.
  """
  def sync_series_batch(%Provider{} = provider, series_list) when is_list(series_list) do
    Logger.info("[GIndex Sync] Syncing batch of #{length(series_list)} series")

    case Series.upsert_batch(provider, series_list) do
      {:ok, _stats} -> {:ok, length(series_list)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Syncs a batch of animes to the database.
  Used by Broadway pipeline for distributed sync.
  """
  def sync_animes_batch(%Provider{} = provider, animes_list) when is_list(animes_list) do
    Logger.info("[GIndex Sync] Syncing batch of #{length(animes_list)} animes")
    Animes.upsert_batch(provider, animes_list)
    {:ok, length(animes_list)}
  end

  defp finalize_provider_sync(
         provider,
         {:ok, movies_count},
         {:ok, series_stats},
         {:ok, animes_stats}
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    total_series = series_stats.series_count + animes_stats.animes_count
    total_episodes = series_stats.episodes_count + animes_stats.episodes_count

    stats = %{
      movies_count: movies_count,
      series_count: series_stats.series_count,
      animes_count: animes_stats.animes_count,
      episodes_count: total_episodes
    }

    provider
    |> Provider.sync_changeset(%{
      sync_status: "completed",
      movies_count: movies_count,
      series_count: total_series,
      vod_synced_at: now
    })
    |> Repo.update()

    Logger.info(
      "[GIndex Sync] Completed: #{movies_count} movies, #{series_stats.series_count} series, " <>
        "#{animes_stats.animes_count} animes, #{total_episodes} episodes synced"
    )

    {:ok, stats}
  end

  defp finalize_provider_sync(provider, {:error, reason}, _series_result, _animes_result) do
    update_status(provider, "failed")
    {:error, reason}
  end

  defp finalize_provider_sync(provider, _movies_result, {:error, reason}, _animes_result) do
    update_status(provider, "failed")
    {:error, reason}
  end

  defp update_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end

  defdelegate sync_animes(provider, base_url, animes_path), to: Animes, as: :sync
  defdelegate sync_series(provider, base_url, series_paths), to: Series, as: :sync
  defdelegate get_movies_path(provider), to: Paths, as: :movies_path
  defdelegate get_series_paths(provider), to: Paths, as: :series_paths
  defdelegate get_animes_path(provider), to: Paths, as: :animes_path
  defdelegate preload_drives(provider), to: Providers
end
