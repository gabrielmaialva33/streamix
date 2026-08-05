defmodule Streamix.Gindex.Sync.Movies do
  @moduledoc """
  Movie synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Iptv

  require Logger

  @batch_size 25

  def sync(%{provider_id: _provider_id} = source, base_url, movies_path) do
    result =
      base_url
      |> Scraper.scrape_movies(movies_path)
      |> consume_stream(source)

    case result do
      {:error, reason} ->
        {:error, reason}

      {:ok, count, batches, failures} ->
        # If more than half the batches failed to upsert, treat the whole
        # run as a failure so ScanRootWorker retries instead of pinning the
        # provider to sync_status=completed with a partial catalog.
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
    end
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during sync: #{inspect(e)}")
      {:error, e}
  end

  defp consume_stream(stream, source) do
    stream
    |> Enum.reduce_while({[], 0, 0, 0}, fn
      {:gindex_error, reason}, _acc ->
        {:halt, {:error, reason}}

      movie, {batch, count, batches, failures} ->
        batch = [movie | batch]

        if length(batch) == @batch_size do
          {count, batches, failures} =
            persist_batch(source, Enum.reverse(batch), count, batches, failures)

          {:cont, {[], count, batches, failures}}
        else
          {:cont, {batch, count, batches, failures}}
        end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      {[], count, batches, failures} ->
        {:ok, count, batches, failures}

      {batch, count, batches, failures} ->
        {count, batches, failures} =
          persist_batch(source, Enum.reverse(batch), count, batches, failures)

        {:ok, count, batches, failures}
    end
  end

  defp persist_batch(source, batch, count, batches, failures) do
    case upsert_batch(source, batch) do
      {:ok, inserted} -> {count + inserted, batches + 1, failures}
      {:error, _reason} -> {count, batches + 1, failures + 1}
    end
  end

  def sync_category(%{provider_id: _provider_id} = source, base_url, category_path) do
    case Scraper.scrape_category(base_url, category_path) do
      {:ok, movies} -> upsert_batch(source, movies)
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_batch(%{provider_id: provider_id}, movies) when is_list(movies) do
    movies = Enum.uniq_by(movies, & &1.stream_id)
    now = DateTime.utc_now(:second)
    entries = Enum.map(movies, &MovieNormalizer.attrs/1)

    case Iptv.upsert_gindex_movies(provider_id, entries, now) do
      {:ok, count} ->
        Logger.debug("[GIndex Sync] Upserted #{count} movies")
        {:ok, count}

      {:error, reason} ->
        Logger.error("[GIndex Sync] Failed to upsert movies: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert movies: #{inspect(e)}")
      {:error, e}
  end
end
