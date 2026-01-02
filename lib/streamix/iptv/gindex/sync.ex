defmodule Streamix.Iptv.Gindex.Sync do
  @moduledoc """
  Synchronization module for GIndex content.

  Fetches data from GIndex servers and syncs to database using UPSERT strategy.
  Preserves record IDs for favorites/history references.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Gindex.Scraper
  alias Streamix.Iptv.{Movie, Provider}
  alias Streamix.Repo

  require Logger

  @batch_size 100

  @doc """
  Syncs all movies from a GIndex provider.

  Returns {:ok, count} on success or {:error, reason} on failure.
  """
  def sync_provider(%Provider{provider_type: :gindex} = provider) do
    Logger.info("[GIndex Sync] Starting sync for provider #{provider.id} (#{provider.name})")

    update_status(provider, "syncing")

    base_url = provider.gindex_url || provider.url
    movies_path = get_movies_path(provider)

    case sync_movies(provider, base_url, movies_path) do
      {:ok, count} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        provider
        |> Provider.sync_changeset(%{
          sync_status: "completed",
          movies_count: count,
          vod_synced_at: now
        })
        |> Repo.update()

        Logger.info("[GIndex Sync] Completed: #{count} movies synced")
        {:ok, count}

      {:error, reason} ->
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
end
