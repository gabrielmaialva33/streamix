defmodule Streamix.Gindex.Sync.Movies do
  @moduledoc """
  Movie synchronization for GIndex providers.
  """

  import Ecto.Query, warn: false

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Iptv.{Movie, Provider}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  @batch_size 25

  def sync(%Provider{} = provider, base_url, movies_path) do
    {count, batches, failures} =
      base_url
      |> Scraper.scrape_movies(movies_path)
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce({0, 0, 0}, fn batch, {count, batches, failures} ->
        case upsert_batch(provider, batch) do
          {:ok, n} -> {count + n, batches + 1, failures}
          {:error, _} -> {count, batches + 1, failures + 1}
        end
      end)

    # If more than half the batches failed to upsert, treat the whole
    # run as a failure so ScanRootWorker retries instead of pinning the
    # provider to sync_status=completed with a partial catalog. The old
    # path swallowed every batch error as `0` and returned {:ok, 0},
    # which is the same false-success that bit us in series/animes.
    cond do
      batches == 0 ->
        Logger.warning("[GIndex Sync] No movie batches produced for #{movies_path}")
        {:error, :empty_scrape}

      failures * 2 > batches ->
        Logger.error(
          "[GIndex Sync] #{failures}/#{batches} movie batches failed for #{movies_path}"
        )

        {:error, {:batch_failures, failures, batches}}

      true ->
        {:ok, count}
    end
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during sync: #{inspect(e)}")
      {:error, e}
  end

  def sync_category(%Provider{} = provider, base_url, category_path) do
    case Scraper.scrape_category(base_url, category_path) do
      {:ok, movies} -> upsert_batch(provider, movies)
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_batch(%Provider{} = provider, movies) when is_list(movies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stream_ids = Enum.map(movies, & &1.stream_id)
    existing_ci_map = existing_catalog_items(provider.id, stream_ids)
    new_sids = Enum.reject(stream_ids, &Map.has_key?(existing_ci_map, &1))
    new_ci_ids = Helpers.pre_create_catalog_items(length(new_sids), "movie", provider.id, now)
    ci_map = Map.merge(existing_ci_map, Enum.zip(new_sids, new_ci_ids) |> Map.new())

    entries =
      Enum.map(movies, fn movie ->
        MovieNormalizer.attrs(movie, provider, ci_map[movie.stream_id], now)
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

  defp existing_catalog_items(_provider_id, []), do: %{}

  defp existing_catalog_items(provider_id, stream_ids) do
    Movie
    |> where(provider_id: ^provider_id)
    |> where([m], m.stream_id in ^stream_ids)
    |> select([m], {m.stream_id, m.catalog_item_id})
    |> Repo.all()
    |> Map.new()
  end
end
