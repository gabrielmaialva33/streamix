defmodule Streamix.Iptv.Content.EmbedplayMovies do
  @moduledoc false

  import Ecto.Query

  alias Streamix.Iptv.{CatalogItem, Movie, Provider}
  alias Streamix.Iptv.Content.SourceEquivalence
  alias Streamix.Repo

  # A provider lock serializes first imports, keeping catalog items and movie
  # rows atomic even when a manual import overlaps a catalog sync.
  def upsert(provider_id, %{tmdb_id: tmdb_id} = attrs)
      when is_integer(provider_id) and is_integer(tmdb_id) and tmdb_id > 0 and
             tmdb_id <= 2_147_483_647 do
    Repo.transact(fn ->
      provider =
        Provider
        |> where(id: ^provider_id, provider_type: :embedplay)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if provider do
        persist(provider_id, tmdb_id, attrs)
      else
        {:error, :not_embedplay_provider}
      end
    end)
  end

  def upsert(_, _), do: {:error, :invalid_embedplay_movie}

  def pending_enrichment(ids) do
    from(movie in Movie,
      join: provider in assoc(movie, :provider),
      where: movie.id in ^ids and provider.provider_type == :embedplay,
      where: is_nil(movie.tmdb_details_at),
      select: movie.id,
      order_by: movie.id
    )
    |> Repo.all()
  end

  defp persist(provider_id, tmdb_id, attrs) do
    # Only identity is sync-owned. Never replace titles, artwork, plot or
    # enrichment bookkeeping with the index's ID-only payload.
    identity = %{tmdb_id: to_string(tmdb_id)}
    identity = if attrs[:imdb_id], do: Map.put(identity, :imdb_id, attrs.imdb_id), else: identity

    result =
      case Repo.get_by(Movie, provider_id: provider_id, stream_id: tmdb_id) do
        nil -> insert(provider_id, tmdb_id, identity)
        movie -> movie |> Movie.changeset(identity) |> Repo.update()
      end

    with {:ok, movie} <- result,
         {:ok, _count} <- SourceEquivalence.reconcile_contents([movie]) do
      {:ok, movie.id}
    end
  end

  defp insert(provider_id, tmdb_id, identity) do
    with {:ok, item} <-
           %CatalogItem{}
           |> CatalogItem.changeset(%{provider_id: provider_id, content_type: "movie"})
           |> Repo.insert() do
      %Movie{}
      |> Movie.changeset(
        Map.merge(identity, %{
          provider_id: provider_id,
          catalog_item_id: item.id,
          stream_id: tmdb_id,
          name: "TMDB #{tmdb_id}",
          container_extension: "m3u8"
        })
      )
      |> Repo.insert()
    end
  end
end
