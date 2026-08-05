defmodule Streamix.Iptv.Sync.Movies do
  @moduledoc """
  Movie (VOD) synchronization from Xtream Codes API.
  """

  alias Streamix.Iptv.{Movie, Provider, XtreamClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Iptv.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Repo

  require Logger

  @sync_opts [
    schema: Movie,
    stream_id_field: :stream_id,
    content_type: "movie"
  ]

  @doc """
  Syncs movies for a provider.
  """
  def sync_movies(%Provider{} = provider) do
    Logger.info("Syncing movies for provider #{provider.id}")

    case XtreamClient.get_vod_streams(provider.url, provider.username, provider.password,
           provider_id: provider.id,
           allow_private_network: provider.is_system
         ) do
      {:ok, streams} ->
        category_lookup = Helpers.build_category_lookup(provider.id, "vod")
        now = DateTime.utc_now(:second)

        upsert_opts =
          @sync_opts
          |> Keyword.put(:attrs_fn, &MovieNormalizer.attrs/3)
          |> Keyword.put(:category_fn, &build_category_assocs/3)
          |> Keyword.put(:type, :movies)
          |> Keyword.put(:provider, provider)

        {count, all_stream_ids} =
          Helpers.upsert_content_batched(streams, provider.id, category_lookup, now, upsert_opts)

        # Sync genres and credits from the raw stream data
        Helpers.sync_genres_and_credits(streams, provider.id, Movie, "movie_genres", "movie_id",
          credits_table: "movie_credits"
        )

        deleted_count = Helpers.delete_orphaned_content(provider.id, all_stream_ids, @sync_opts)

        now_utc = DateTime.utc_now(:second)

        provider
        |> Provider.sync_changeset(%{movies_count: count, vod_synced_at: now_utc})
        |> Repo.update()

        Logger.info("Synced #{count} movies, removed #{deleted_count} orphaned")
        {:ok, count}

      {:error, reason} ->
        {:error, {:vod_sync_failed, reason}}
    end
  end

  defp build_category_assocs(streams, returned, category_lookup) do
    Helpers.build_category_assocs(streams, returned, category_lookup, fk_column: :movie_id)
  end
end
