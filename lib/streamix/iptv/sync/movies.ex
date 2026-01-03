defmodule Streamix.Iptv.Sync.Movies do
  @moduledoc """
  Movie (VOD) synchronization from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Movie, Provider, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  @doc """
  Syncs movies for a provider.
  """
  def sync_movies(%Provider{} = provider) do
    Logger.info("Syncing movies for provider #{provider.id}")

    case XtreamClient.get_vod_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "vod")
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
    |> Enum.chunk_every(Helpers.batch_size())
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
      year: Helpers.parse_year(stream["year"]),
      stream_icon: stream["stream_icon"],
      rating: Helpers.parse_decimal(stream["rating"]),
      rating_5based: Helpers.parse_decimal(stream["rating_5based"]),
      genre: stream["genre"],
      cast: stream["cast"],
      director: stream["director"],
      plot: stream["plot"],
      container_extension: stream["container_extension"],
      duration_secs: stream["duration_secs"],
      duration: stream["duration"],
      tmdb_id: Helpers.to_string_or_nil(stream["tmdb_id"]),
      imdb_id: Helpers.to_string_or_nil(stream["imdb_id"]),
      backdrop_path: Helpers.normalize_backdrop(stream["backdrop_path"]),
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
end
