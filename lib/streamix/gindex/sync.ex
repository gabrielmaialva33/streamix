defmodule Streamix.Gindex.Sync do
  @moduledoc """
  Public facade for GIndex provider synchronization.

  Fetches data from GIndex servers and syncs to the database using an UPSERT
  strategy that preserves record IDs for favorites/history references.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.{Animes, Movies, Paths, Series}
  alias Streamix.Iptv

  require Logger

  @type kind :: :movies | :series | :animes

  @doc """
  Syncs all content (movies, series, and animes) from a GIndex provider.

  Returns `{:ok, stats}` on success or `{:error, reason}` on failure.
  """
  @spec sync_provider(term()) :: {:ok, map()} | {:error, term()}
  def sync_provider(provider) do
    case Iptv.gindex_sync_source(provider) do
      {:ok, source} ->
        start_provider_sync(source)

      {:error, :not_gindex_provider} = error ->
        Logger.warning("[GIndex Sync] Provider #{provider_id(provider)} is not a GIndex provider")

        error
    end
  end

  defp start_provider_sync(source) do
    Logger.info("[GIndex Sync] Starting sync for provider #{source.provider_id} (#{source.name})")

    case update_status(source, "syncing") do
      :ok -> do_sync_provider(source)
      {:error, reason} -> provider_state_error("start", reason)
    end
  end

  defp do_sync_provider(source) do
    movies_result = Movies.sync(source, source.base_url, Paths.movies_path(source))
    series_result = Series.sync(source, source.base_url, Paths.series_paths(source))
    animes_result = Animes.sync(source, source.base_url, Paths.animes_path(source))

    finalize_provider_sync(source, movies_result, series_result, animes_result)
  end

  @doc """
  Syncs movies from a specific category path.
  """
  @spec sync_category(term(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_category(provider, category_path) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      Movies.sync_category(source, source.base_url, category_path)
    end
  end

  @doc """
  Lists available categories in the GIndex.
  """
  @spec list_categories(term(), String.t() | nil) :: {:ok, list()} | {:error, term()}
  def list_categories(provider, movies_path \\ nil) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      Scraper.list_categories(source.base_url, movies_path || Paths.movies_path(source))
    end
  end

  @doc """
  Syncs a single root path for a given kind.
  """
  @spec sync_kind(term(), String.t(), String.t(), kind(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_kind(provider, base_url, path, kind, opts \\ []) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      do_sync_kind(source, base_url, path, kind, opts)
    end
  end

  @doc """
  Syncs one provider path using the provider's configured GIndex endpoint.

  Queue consumers should prefer this entrypoint over carrying provider endpoint
  details in their messages.
  """
  @spec sync_path(term(), String.t(), kind(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_path(provider, path, kind, opts \\ []) do
    with :ok <- validate_path(path),
         :ok <- validate_kind(kind),
         {:ok, source} <- Iptv.gindex_sync_source(provider) do
      do_sync_kind(source, source.base_url, path, kind, opts)
    end
  end

  defp do_sync_kind(source, base_url, path, :movies, _opts) do
    case Movies.sync(source, base_url, path) do
      {:ok, count} -> {:ok, %{movies_count: count}}
      {:error, _reason} = error -> error
    end
  end

  defp do_sync_kind(source, base_url, path, :series, opts) do
    Series.sync(source, base_url, [path], opts)
  end

  defp do_sync_kind(source, base_url, path, :animes, _opts) do
    Animes.sync(source, base_url, path)
  end

  defp validate_path(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, :invalid_sync_path}, else: :ok
  end

  defp validate_path(_path), do: {:error, :invalid_sync_path}

  defp validate_kind(kind) when kind in [:movies, :series, :animes], do: :ok
  defp validate_kind(kind), do: {:error, {:unsupported_kind, kind}}

  @doc """
  Syncs a batch of movies to the database.
  Used by Broadway pipeline for distributed sync.
  """
  @spec sync_movies_batch(term(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_movies_batch(provider, movies) when is_list(movies) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      Logger.info("[GIndex Sync] Syncing batch of #{length(movies)} movies")
      Movies.upsert_batch(source, movies)
    end
  end

  @doc """
  Syncs a batch of series to the database.
  Used by Broadway pipeline for distributed sync.
  """
  @spec sync_series_batch(term(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_series_batch(provider, series_list) when is_list(series_list) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      Logger.info("[GIndex Sync] Syncing batch of #{length(series_list)} series")

      case Series.upsert_batch(source, series_list) do
        {:ok, _stats} -> {:ok, length(series_list)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Syncs a batch of animes to the database.
  Used by Broadway pipeline for distributed sync.
  """
  @spec sync_animes_batch(term(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_animes_batch(provider, animes_list) when is_list(animes_list) do
    with {:ok, source} <- Iptv.gindex_sync_source(provider) do
      Logger.info("[GIndex Sync] Syncing batch of #{length(animes_list)} animes")

      case Animes.upsert_batch(source, animes_list) do
        {:ok, _stats} -> {:ok, length(animes_list)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp finalize_provider_sync(
         source,
         {:ok, movies_count},
         {:ok, series_stats},
         {:ok, animes_stats}
       ) do
    total_series = series_stats.series_count + animes_stats.animes_count
    total_episodes = series_stats.episodes_count + animes_stats.episodes_count

    stats = %{
      movies_count: movies_count,
      series_count: series_stats.series_count,
      animes_count: animes_stats.animes_count,
      episodes_count: total_episodes
    }

    attrs = %{
      sync_status: "completed",
      movies_count: movies_count,
      series_count: total_series,
      vod_synced_at: DateTime.utc_now(:second)
    }

    case Iptv.update_gindex_sync(source.provider_id, attrs) do
      :ok ->
        Logger.info(
          "[GIndex Sync] Completed: #{movies_count} movies, #{series_stats.series_count} series, " <>
            "#{animes_stats.animes_count} animes, #{total_episodes} episodes synced"
        )

        {:ok, stats}

      {:error, reason} ->
        provider_state_error("finish", reason)
    end
  end

  defp finalize_provider_sync(source, {:error, reason}, _series_result, _animes_result),
    do: fail_provider_sync(source, reason)

  defp finalize_provider_sync(source, _movies_result, {:error, reason}, _animes_result),
    do: fail_provider_sync(source, reason)

  defp finalize_provider_sync(source, _movies_result, _series_result, {:error, reason}),
    do: fail_provider_sync(source, reason)

  defp fail_provider_sync(source, reason) do
    case update_status(source, "failed") do
      :ok ->
        :ok

      {:error, state_reason} ->
        Logger.error("[GIndex Sync] Failed to persist failed state: #{inspect(state_reason)}")
    end

    {:error, reason}
  end

  defp update_status(source, status) do
    Iptv.update_gindex_sync(source.provider_id, %{sync_status: status})
  end

  defp provider_state_error(stage, reason) do
    Logger.error("[GIndex Sync] Could not #{stage} provider state update: #{inspect(reason)}")

    {:error, {:provider_state_update_failed, reason}}
  end

  defp provider_id(%{id: id}), do: id
  defp provider_id(_provider), do: "unknown"
end
