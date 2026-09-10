defmodule Streamix.Embedplay.Catalog do
  @moduledoc false

  alias Streamix.Catalog, as: MediaCatalog
  alias Streamix.Embedplay
  alias Streamix.Embedplay.CatalogClient
  alias Streamix.Providers
  alias Streamix.Workers.{SyncEmbedplayProviderWorker, TmdbDetailsWorker}

  def enqueue_sync do
    if Embedplay.enabled?() do
      %{} |> SyncEmbedplayProviderWorker.new() |> Oban.insert()
    else
      {:error, :embedplay_disabled}
    end
  end

  # For the vertical slice, import an operator-confirmed movie without a full
  # catalog walk. Availability is finally checked by the playback resolver.
  def import_movie(tmdb_id, imdb_id) do
    with {:ok, attrs} <- normalize(%{"tmdb_id" => tmdb_id, "imdb_id" => imdb_id}),
         {:ok, %{id: provider_id, is_active: true}} <- Providers.ensure_embedplay_provider(),
         {:ok, movie_id} <- MediaCatalog.upsert_embedplay_movie(provider_id, attrs),
         {:ok, _provider} <- Providers.refresh_embedplay_counts(provider_id),
         {:ok, _job} <- enqueue_enrichment([movie_id]) do
      {:ok, movie_id}
    else
      {:ok, :disabled} -> {:error, :embedplay_disabled}
      {:ok, %{is_active: false}} -> {:error, :provider_inactive}
      error -> error
    end
  end

  def sync do
    with true <- Embedplay.enabled?(),
         {:ok, %{is_active: true} = provider} <- Providers.ensure_embedplay_provider(),
         {:ok, movies} <- CatalogClient.movies() do
      run_sync(provider, movies)
    else
      false -> {:error, :embedplay_disabled}
      {:ok, _provider} -> {:error, :provider_inactive}
      error -> error
    end
  end

  defp run_sync(provider, movies) do
    with {:ok, _provider} <- Providers.update_provider(provider, %{sync_status: "syncing"}) do
      case import_all(provider.id, movies) do
        {:ok, stats} ->
          finish_sync(provider.id, stats)

        {:error, _reason} = error ->
          Providers.update_provider(provider, %{sync_status: "error"})
          error
      end
    end
  end

  defp import_all(provider_id, movies) do
    movies
    |> Enum.reduce({[], 0}, fn movie, {entries, skipped} ->
      case normalize(movie) do
        {:ok, attrs} -> {[attrs | entries], skipped}
        {:error, _reason} -> {entries, skipped + 1}
      end
    end)
    |> then(fn {entries, skipped} ->
      entries = Enum.uniq_by(entries, & &1.tmdb_id)

      if entries == [] do
        {:error, :no_supported_movies}
      else
        persist_all(provider_id, entries, skipped)
      end
    end)
  end

  defp persist_all(provider_id, entries, skipped) do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn attrs, {:ok, ids} ->
        case MediaCatalog.upsert_embedplay_movie(provider_id, attrs) do
          {:ok, id} -> {:cont, {:ok, [id | ids]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, ids} <- result,
         :ok <- enqueue_batches(ids) do
      {:ok, %{imported: length(ids), skipped: skipped}}
    end
  end

  defp finish_sync(provider_id, stats) do
    case Providers.refresh_embedplay_counts(provider_id, %{
           sync_status: "completed",
           vod_synced_at: DateTime.utc_now(:second)
         }) do
      {:ok, _provider} -> {:ok, stats}
      error -> error
    end
  end

  defp enqueue_batches(ids) do
    ids
    |> Enum.chunk_every(25)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {batch, index}, :ok ->
      case enqueue_enrichment(batch, index * 15) do
        {:ok, _job} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp enqueue_enrichment(ids, delay \\ 0) do
    case MediaCatalog.embedplay_pending_enrichment(ids) do
      [] ->
        {:ok, :already_enriched}

      pending ->
        %{"kind" => "movie", "ids" => pending}
        |> TmdbDetailsWorker.new(
          schedule_in: delay,
          unique: [period: 3_600, fields: [:worker, :args], keys: [:kind, :ids]]
        )
        |> Oban.insert()
    end
  end

  defp normalize(%{"tmdb_id" => tmdb_id} = movie) do
    with {:ok, id} <- tmdb_id(tmdb_id),
         {:ok, imdb_id} <- imdb_id(movie["imdb_id"]) do
      {:ok, %{tmdb_id: id, imdb_id: imdb_id}}
    end
  end

  defp normalize(_movie), do: {:error, :invalid_movie_identity}

  defp tmdb_id(id) when is_integer(id) and id > 0 and id <= 2_147_483_647, do: {:ok, id}

  defp tmdb_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> tmdb_id(id)
      _ -> {:error, :invalid_movie_identity}
    end
  end

  defp tmdb_id(_id), do: {:error, :invalid_movie_identity}
  defp imdb_id(id) when id in [nil, ""], do: {:ok, nil}

  defp imdb_id(id) when is_binary(id) do
    if Regex.match?(~r/^tt\d{5,12}$/, id), do: {:ok, id}, else: {:error, :invalid_movie_identity}
  end

  defp imdb_id(_id), do: {:error, :invalid_movie_identity}
end
