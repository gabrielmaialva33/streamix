defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  Public catalog API for TV app and other clients.
  Provides read-only access to content from public/global providers.
  """
  use StreamixWeb, :controller

  alias Streamix.Iptv
  alias Streamix.Repo

  @doc """
  Handle CORS preflight OPTIONS requests.
  """
  def options(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> send_resp(204, "")
  end

  @doc """
  GET /api/v1/catalog/featured
  Returns featured content (hero) and stats for the home page.
  """
  def featured(conn, _params) do
    featured = build_featured_content()
    stats = Iptv.get_public_stats()

    json(conn, %{
      featured: featured,
      stats: stats
    })
  end

  defp build_featured_content do
    case Iptv.get_featured_content() do
      {:movie, movie} ->
        %{
          id: movie.id,
          type: "movie",
          title: movie.title || movie.name,
          name: movie.name,
          year: movie.year,
          rating: movie.rating && Decimal.to_float(movie.rating),
          genre: movie.genre,
          plot: movie.plot,
          poster: movie.stream_icon,
          backdrop: movie.backdrop_path
        }

      {:series, series} ->
        %{
          id: series.id,
          type: "series",
          title: series.title || series.name,
          name: series.name,
          year: series.year,
          rating: series.rating && Decimal.to_float(series.rating),
          genre: series.genre,
          plot: series.plot,
          poster: series.cover,
          backdrop: series.backdrop_path
        }

      nil ->
        nil
    end
  end

  @doc """
  GET /api/v1/catalog/movies
  Returns paginated list of movies from public/global providers.
  Query params: limit, offset, category_id, search
  """
  def movies(conn, params) do
    provider = Iptv.get_global_provider()

    if provider do
      opts = [
        limit: parse_int(params["limit"], 20),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"]
      ]

      movies = Iptv.list_movies(provider.id, opts)
      total = Iptv.count_movies(provider.id)

      json(conn, %{
        movies: Enum.map(movies, &serialize_movie/1),
        total: total,
        has_more: opts[:offset] + length(movies) < total
      })
    else
      json(conn, %{movies: [], total: 0, has_more: false})
    end
  end

  @doc """
  GET /api/v1/catalog/movies/:id
  Returns a single movie with full details.
  """
  def show_movie(conn, %{"id" => id}) do
    case Iptv.get_public_movie(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Movie not found"})

      movie ->
        {:ok, movie} = Iptv.fetch_movie_info(movie)
        json(conn, serialize_movie_detail(movie))
    end
  end

  @doc """
  GET /api/v1/catalog/series
  Returns paginated list of series from public/global providers.
  Query params: limit, offset, category_id, search
  """
  def series(conn, params) do
    provider = Iptv.get_global_provider()

    if provider do
      opts = [
        limit: parse_int(params["limit"], 20),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"]
      ]

      series_list = Iptv.list_series(provider.id, opts)
      total = Iptv.count_series(provider.id)

      json(conn, %{
        series: Enum.map(series_list, &serialize_series/1),
        total: total,
        has_more: opts[:offset] + length(series_list) < total
      })
    else
      json(conn, %{series: [], total: 0, has_more: false})
    end
  end

  @doc """
  GET /api/v1/catalog/series/:id
  Returns a single series with seasons and episodes.
  """
  def show_series(conn, %{"id" => id}) do
    {:ok, series} = Iptv.get_series_with_sync!(id)
    json(conn, serialize_series_detail(series))
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Series not found"})
  end

  @doc """
  GET /api/v1/catalog/series/:series_id/episodes/:id
  Returns a single episode with stream info.
  """
  def show_episode(conn, %{"id" => id}) do
    case Iptv.get_public_episode(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})

      episode ->
        {:ok, episode} = Iptv.fetch_episode_info(episode)
        json(conn, serialize_episode_detail(episode))
    end
  end

  @doc """
  GET /api/v1/catalog/channels
  Returns paginated list of channels from public/global providers.
  Query params: limit, offset, category_id, search
  """
  def channels(conn, params) do
    provider = Iptv.get_global_provider()

    if provider do
      opts = [
        limit: parse_int(params["limit"], 30),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"]
      ]

      channels = Iptv.list_live_channels(provider.id, opts)
      total = Iptv.count_live_channels(provider.id)

      json(conn, %{
        channels: Enum.map(channels, &serialize_channel/1),
        total: total,
        has_more: opts[:offset] + length(channels) < total
      })
    else
      json(conn, %{channels: [], total: 0, has_more: false})
    end
  end

  @doc """
  GET /api/v1/catalog/channels/:id
  Returns a single channel with stream URL.
  """
  def show_channel(conn, %{"id" => id}) do
    case Iptv.get_public_channel(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Channel not found"})

      channel ->
        json(conn, serialize_channel_detail(channel))
    end
  end

  @doc """
  GET /api/v1/catalog/categories?type=movie|series|live
  Returns categories for a content type.
  """
  def categories(conn, params) do
    provider = Iptv.get_global_provider()
    type = params["type"] || "movie"

    if provider do
      categories = Iptv.list_categories(provider.id, type)

      json(
        conn,
        Enum.map(categories, fn cat ->
          %{
            id: cat.id,
            name: cat.name,
            type: cat.type
          }
        end)
      )
    else
      json(conn, [])
    end
  end

  @doc """
  GET /api/v1/catalog/search?q=query
  Searches across movies, series, and channels.
  """
  def search(conn, %{"q" => query}) when is_binary(query) and byte_size(query) >= 2 do
    movies = Iptv.search_public_movies(query, limit: 10)
    series = Iptv.search_public_series(query, limit: 10)
    channels = Iptv.search_public_channels(query, limit: 10)

    json(conn, %{
      movies: Enum.map(movies, &serialize_movie/1),
      series: Enum.map(series, &serialize_series/1),
      channels: Enum.map(channels, &serialize_channel/1)
    })
  end

  def search(conn, _params) do
    json(conn, %{movies: [], series: [], channels: []})
  end

  # Serializers
  defp serialize_movie(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: movie.genre,
      poster: movie.stream_icon,
      duration: movie.duration
    }
  end

  defp serialize_movie_detail(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: movie.genre,
      plot: movie.plot,
      cast: movie.cast,
      director: movie.director,
      duration: movie.duration,
      content_rating: movie.content_rating,
      tagline: movie.tagline,
      poster: movie.stream_icon,
      backdrop: movie.backdrop_path,
      youtube_trailer: movie.youtube_trailer,
      stream_url: build_stream_url(movie)
    }
  end

  defp serialize_series(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: series.genre,
      poster: series.cover,
      season_count: series.season_count,
      episode_count: series.episode_count
    }
  end

  defp serialize_series_detail(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: series.genre,
      plot: series.plot,
      cast: series.cast,
      director: series.director,
      poster: series.cover,
      backdrop: series.backdrop_path,
      season_count: series.season_count,
      episode_count: series.episode_count,
      seasons: Enum.map(series.seasons || [], &serialize_season/1)
    }
  end

  defp serialize_season(season) do
    %{
      id: season.id,
      name: season.name,
      season_number: season.season_number,
      episode_count: length(season.episodes || []),
      episodes: Enum.map(season.episodes || [], &serialize_episode/1)
    }
  end

  defp serialize_episode(episode) do
    %{
      id: episode.id,
      title: episode.title,
      episode_num: episode.episode_num,
      plot: episode.plot,
      still: episode.still_path,
      duration: episode.duration,
      air_date: episode.air_date
    }
  end

  defp serialize_episode_detail(episode) do
    series = episode.season.series

    %{
      id: episode.id,
      title: episode.title,
      episode_num: episode.episode_num,
      season_number: episode.season.season_number,
      plot: episode.plot,
      still: episode.still_path,
      duration: episode.duration,
      air_date: episode.air_date,
      series_id: series.id,
      series_name: series.name,
      stream_url: build_episode_stream_url(episode, series)
    }
  end

  defp serialize_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: channel.stream_icon
    }
  end

  defp serialize_channel_detail(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: channel.stream_icon,
      stream_url: build_channel_stream_url(channel)
    }
  end

  @doc """
  Returns stream URL for a movie.
  """
  def movie_stream(conn, %{"id" => id}) do
    case Iptv.get_movie(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Movie not found"})

      movie ->
        movie = Repo.preload(movie, :provider)
        json(conn, %{stream_url: build_stream_url(movie)})
    end
  end

  @doc """
  Returns stream URL for an episode.
  """
  def episode_stream(conn, %{"id" => id}) do
    case Iptv.get_episode(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Episode not found"})

      episode ->
        episode = Repo.preload(episode, season: [series: :provider])
        json(conn, %{stream_url: build_episode_stream_url(episode, episode.season.series)})
    end
  end

  @doc """
  Returns stream URL for a channel.
  """
  def channel_stream(conn, %{"id" => id}) do
    case Iptv.get_channel(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Channel not found"})

      channel ->
        channel = Repo.preload(channel, :provider)
        json(conn, %{stream_url: build_channel_stream_url(channel)})
    end
  end

  # Stream URL Builders
  defp build_stream_url(movie) do
    provider = movie.provider
    ext = movie.container_extension || "mp4"
    "#{provider.url}/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.#{ext}"
  end

  defp build_episode_stream_url(episode, series) do
    provider = series.provider
    ext = episode.container_extension || "mp4"

    "#{provider.url}/series/#{provider.username}/#{provider.password}/#{episode.episode_id}.#{ext}"
  end

  defp build_channel_stream_url(channel) do
    provider = channel.provider
    "#{provider.url}/live/#{provider.username}/#{provider.password}/#{channel.stream_id}.m3u8"
  end

  # Helpers
  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default
end
