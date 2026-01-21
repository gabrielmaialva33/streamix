defmodule Streamix.Iptv.Sync.Movies do
  @moduledoc """
  Movie (VOD) synchronization from Xtream Codes API.
  """

  alias Streamix.Iptv.{Movie, Provider, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  require Logger

  @sync_opts [
    schema: Movie,
    table_name: "movies",
    join_table: "movie_categories",
    fk_column: "movie_id"
  ]

  @doc """
  Syncs movies for a provider.
  """
  def sync_movies(%Provider{} = provider) do
    Logger.info("Syncing movies for provider #{provider.id}")

    case XtreamClient.get_vod_streams(provider.url, provider.username, provider.password) do
      {:ok, streams} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "vod")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        upsert_opts =
          @sync_opts
          |> Keyword.put(:attrs_fn, &movie_attrs/3)
          |> Keyword.put(:category_fn, &build_category_assocs/3)
          |> Keyword.put(:type, :movies)
          |> Keyword.put(:provider, provider)

        {count, all_stream_ids} =
          Helpers.upsert_content_batched(streams, provider.id, category_lookup, now, upsert_opts)

        deleted_count = Helpers.delete_orphaned_content(provider.id, all_stream_ids, @sync_opts)

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

  defp build_category_assocs(streams, returned, category_lookup) do
    Helpers.build_category_assocs(streams, returned, category_lookup, fk_column: :movie_id)
  end
end
