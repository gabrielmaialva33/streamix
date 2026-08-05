defmodule Streamix.Iptv.Content.GindexStream do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Movie, Provider, Season, Series}
  alias Streamix.Repo

  @type content_type :: :movie | :episode
  @type source :: %{
          base_url: String.t(),
          path: String.t(),
          cached_url: String.t() | nil,
          cached_until: DateTime.t() | nil
        }
  @type source_error ::
          :movie_not_found
          | :episode_not_found
          | :not_gindex_movie
          | :not_gindex_episode
          | :unsupported_type

  @spec get_source(content_type(), pos_integer()) :: {:ok, source()} | {:error, source_error()}
  def get_source(:movie, movie_id) when is_integer(movie_id) and movie_id > 0 do
    Movie
    |> join(:inner, [movie], provider in Provider, on: provider.id == movie.provider_id)
    |> where([movie], movie.id == ^movie_id)
    |> select([movie, provider], %{
      path: movie.gindex_path,
      gindex_url: provider.gindex_url,
      provider_url: provider.url,
      cached_url: movie.gindex_url_cached,
      cached_until: movie.gindex_url_expires_at
    })
    |> Repo.one()
    |> normalize_source(:movie)
  end

  def get_source(:episode, episode_id) when is_integer(episode_id) and episode_id > 0 do
    Episode
    |> join(:inner, [episode], season in Season, on: season.id == episode.season_id)
    |> join(:inner, [_episode, season], series in Series, on: series.id == season.series_id)
    |> join(:inner, [_episode, _season, series], provider in Provider,
      on: provider.id == series.provider_id
    )
    |> where([episode], episode.id == ^episode_id)
    |> select([episode, _season, _series, provider], %{
      path: episode.gindex_path,
      gindex_url: provider.gindex_url,
      provider_url: provider.url,
      cached_url: episode.gindex_url_cached,
      cached_until: episode.gindex_url_expires_at
    })
    |> Repo.one()
    |> normalize_source(:episode)
  end

  def get_source(:movie, _movie_id), do: {:error, :movie_not_found}
  def get_source(:episode, _episode_id), do: {:error, :episode_not_found}
  def get_source(_type, _id), do: {:error, :unsupported_type}

  @spec put_cache(content_type(), pos_integer(), String.t(), DateTime.t()) ::
          :ok | {:error, :invalid_cache | :not_found | :unsupported_type}
  def put_cache(type, id, url, %DateTime{} = expires_at)
      when type in [:movie, :episode] and is_integer(id) and id > 0 and is_binary(url) and
             url != "" do
    schema = if type == :movie, do: Movie, else: Episode

    {count, _rows} =
      schema
      |> where(id: ^id)
      |> Repo.update_all(set: [gindex_url_cached: url, gindex_url_expires_at: expires_at])

    if count == 1, do: :ok, else: {:error, :not_found}
  end

  def put_cache(type, _id, _url, _expires_at) when type in [:movie, :episode],
    do: {:error, :invalid_cache}

  def put_cache(_type, _id, _url, _expires_at), do: {:error, :unsupported_type}

  defp normalize_source(nil, :movie), do: {:error, :movie_not_found}
  defp normalize_source(nil, :episode), do: {:error, :episode_not_found}
  defp normalize_source(%{path: nil}, :movie), do: {:error, :not_gindex_movie}
  defp normalize_source(%{path: nil}, :episode), do: {:error, :not_gindex_episode}

  defp normalize_source(source, _type) do
    {:ok,
     %{
       base_url: source.gindex_url || source.provider_url,
       path: source.path,
       cached_url: source.cached_url,
       cached_until: source.cached_until
     }}
  end
end
