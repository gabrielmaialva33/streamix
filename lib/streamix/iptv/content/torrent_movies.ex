defmodule Streamix.Iptv.Content.TorrentMovies do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.{AdultFilter, CatalogItem, Movie, Provider}
  alias Streamix.Repo

  @movie_fields ~w(stream_id name title year stream_icon rating plot tmdb_id imdb_id duration_secs)a

  @spec upsert(pos_integer(), map()) :: {:ok, pos_integer()} | {:error, term()}
  def upsert(provider_id, attrs)
      when is_integer(provider_id) and provider_id > 0 and is_map(attrs) do
    attrs = Map.take(attrs, @movie_fields)
    stream_id = Map.get(attrs, :stream_id)

    Repo.transact(fn ->
      case Repo.get_by(Movie, provider_id: provider_id, stream_id: stream_id) do
        nil -> insert_movie(provider_id, attrs)
        movie -> update_movie(movie, attrs)
      end
    end)
  end

  def upsert(_provider_id, _attrs), do: {:error, :invalid_torrent_movie}

  @spec list(pos_integer(), keyword()) :: [Movie.t()]
  def list(provider_id, opts \\ []) when is_integer(provider_id) and provider_id > 0 do
    limit = Keyword.get(opts, :limit, 48)
    offset = Keyword.get(opts, :offset, 0)

    Movie
    |> join(:inner, [movie], stats in "torrent_movie_stats", on: stats.movie_id == movie.id)
    |> where([movie], movie.provider_id == ^provider_id)
    |> maybe_search(Keyword.get(opts, :search))
    |> maybe_exclude_adult(provider_id, Keyword.get(opts, :show_adult, false))
    |> order_by([movie, stats], desc: stats.max_seeders, desc: movie.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([movie, stats], %{
      movie
      | torrent_seeders: stats.max_seeders,
        torrent_quality: stats.top_quality
    })
    |> Repo.all()
  end

  @spec count(pos_integer(), keyword()) :: non_neg_integer()
  def count(provider_id, opts \\ []) when is_integer(provider_id) and provider_id > 0 do
    Movie
    |> join(:inner, [movie], stats in "torrent_movie_stats", on: stats.movie_id == movie.id)
    |> where([movie], movie.provider_id == ^provider_id)
    |> maybe_exclude_adult(provider_id, Keyword.get(opts, :show_adult, false))
    |> Repo.aggregate(:count)
  end

  @spec get_for_playback(pos_integer()) ::
          {:ok, Movie.t(), Provider.t()} | {:error, :not_found}
  def get_for_playback(movie_id) when is_integer(movie_id) and movie_id > 0 do
    query =
      from movie in Movie,
        join: provider in assoc(movie, :provider),
        where: movie.id == ^movie_id and provider.provider_type == :torrent,
        preload: [provider: provider]

    case Repo.one(query) do
      %Movie{provider: %Provider{} = provider} = movie -> {:ok, movie, provider}
      nil -> {:error, :not_found}
    end
  end

  def get_for_playback(_movie_id), do: {:error, :not_found}

  defp insert_movie(provider_id, attrs) do
    with {:ok, catalog_item} <- insert_catalog_item(provider_id),
         {:ok, movie} <-
           %Movie{}
           |> Movie.changeset(
             attrs
             |> Map.put(:provider_id, provider_id)
             |> Map.put(:catalog_item_id, catalog_item.id)
           )
           |> Repo.insert() do
      {:ok, movie.id}
    end
  end

  defp insert_catalog_item(provider_id) do
    %CatalogItem{}
    |> CatalogItem.changeset(%{content_type: "movie", provider_id: provider_id})
    |> Repo.insert()
  end

  defp update_movie(movie, attrs) do
    case movie |> Movie.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, updated.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_search(query, search) when is_binary(search) and search != "" do
    escaped = Helpers.escape_like(String.trim(search))
    pattern = "%#{escaped}%"

    where(query, [movie], ilike(movie.name, ^pattern) or ilike(movie.title, ^pattern))
  end

  defp maybe_search(query, _search), do: query

  defp maybe_exclude_adult(query, _provider_id, true), do: query

  defp maybe_exclude_adult(query, provider_id, false) do
    AdultFilter.exclude_adult_movies(query, provider_id)
  end
end
