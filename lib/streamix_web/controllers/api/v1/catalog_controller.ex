defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  API controller for public catalog access.
  Used by the TV app and other clients that need JSON data.
  """
  use StreamixWeb, :controller

  alias Streamix.Iptv
  alias Streamix.Iptv.{Movie, Episode, LiveChannel}

  @default_limit 20
  @max_limit 100

  # GET /api/v1/catalog/featured
  def featured(conn, _params) do
    featured = Iptv.get_featured_content()
    stats = Iptv.get_public_stats()

    json(conn, %{
      featured: render_featured(featured),
      stats: stats
    })
  end

  # GET /api/v1/catalog/movies
  def movies(conn, params) do
    opts = parse_list_opts(params)
    movies = Iptv.list_public_movies(opts)
    total = length(movies)

    json(conn, %{
      movies: Enum.map(movies, &render_movie_list/1),
      total: total,
      has_more: total >= opts[:limit]
    })
  end

  # GET /api/v1/catalog/movies/:id
  def show_movie(conn, %{"id" => id}) do
    case Iptv.get_public_movie(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Movie not found"})

      movie ->
        json(conn, %{movie: render_movie_detail(movie)})
    end
  end

  # GET /api/v1/catalog/series
  def series(conn, params) do
    opts = parse_list_opts(params)
    series_list = Iptv.list_public_series(opts)
    total = length(series_list)

    json(conn, %{
      series: Enum.map(series_list, &render_series_list/1),
      total: total,
      has_more: total >= opts[:limit]
    })
  end

  # GET /api/v1/catalog/series/:id
  def show_series(conn, %{"id" => id}) do
    case Iptv.get_series_with_seasons(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Series not found"})

      series ->
        # Verify it's a public series
        case Iptv.get_public_series(id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Series not found"})

          _public_series ->
            json(conn, %{series: render_series_detail(series)})
        end
    end
  end

  # GET /api/v1/catalog/series/:series_id/episodes/:id
  def show_episode(conn, %{"series_id" => _series_id, "id" => id}) do
    case Iptv.get_public_episode(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})

      episode ->
        episode = Streamix.Repo.preload(episode, season: [series: :provider])
        json(conn, %{episode: render_episode_detail(episode)})
    end
  end

  # GET /api/v1/catalog/channels
  def channels(conn, params) do
    opts = parse_list_opts(params)
    channels = Iptv.list_public_channels(opts)
    total = length(channels)

    json(conn, %{
      channels: Enum.map(channels, &render_channel_list/1),
      total: total,
      has_more: total >= opts[:limit]
    })
  end

  # GET /api/v1/catalog/channels/:id
  def show_channel(conn, %{"id" => id}) do
    case Iptv.get_public_channel(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Channel not found"})

      channel ->
        json(conn, %{channel: render_channel_detail(channel)})
    end
  end

  # GET /api/v1/catalog/categories
  def categories(conn, params) do
    type = params["type"]
    # Get categories from the global provider
    case Iptv.get_global_provider() do
      nil ->
        json(conn, %{categories: []})

      provider ->
        categories = Iptv.list_categories(provider.id, type)
        json(conn, %{categories: Enum.map(categories, &render_category/1)})
    end
  end

  # GET /api/v1/catalog/search
  def search(conn, %{"q" => query} = params) when byte_size(query) > 0 do
    opts = parse_list_opts(params)
    type = params["type"] || "all"

    result =
      case type do
        "movies" ->
          %{movies: search_movies(query, opts)}

        "series" ->
          %{series: search_series(query, opts)}

        "channels" ->
          %{channels: search_channels(query, opts)}

        _ ->
          %{
            movies: search_movies(query, Keyword.put(opts, :limit, 10)),
            series: search_series(query, Keyword.put(opts, :limit, 10)),
            channels: search_channels(query, Keyword.put(opts, :limit, 10))
          }
      end

    json(conn, result)
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing search query parameter 'q'"})
  end

  # Private helpers

  defp parse_list_opts(params) do
    limit =
      params
      |> Map.get("limit", @default_limit)
      |> to_integer(@default_limit)
      |> min(@max_limit)

    offset =
      params
      |> Map.get("offset", 0)
      |> to_integer(0)

    search = Map.get(params, "search")
    category_id = Map.get(params, "category_id")
    genre = Map.get(params, "genre")

    opts = [limit: limit, offset: offset]
    opts = if search, do: Keyword.put(opts, :search, search), else: opts
    opts = if category_id, do: Keyword.put(opts, :category_id, category_id), else: opts
    opts = if genre, do: Keyword.put(opts, :genre, genre), else: opts
    opts
  end

  defp to_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_integer(val, _default) when is_integer(val), do: val
  defp to_integer(_, default), do: default

  defp search_movies(query, opts) do
    query
    |> Iptv.search_public_movies(opts)
    |> Enum.map(&render_movie_list/1)
  end

  defp search_series(query, opts) do
    query
    |> Iptv.search_public_series(opts)
    |> Enum.map(&render_series_list/1)
  end

  defp search_channels(query, opts) do
    query
    |> Iptv.search_public_channels(opts)
    |> Enum.map(&render_channel_list/1)
  end

  # Render functions

  defp render_featured(nil), do: nil

  defp render_featured({:movie, movie}) do
    %{
      type: "movie",
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      backdrop: List.first(movie.backdrop_path || []),
      poster: movie.stream_icon,
      plot: movie.plot,
      rating: movie.rating,
      genre: movie.genre
    }
  end

  defp render_featured({:series, series}) do
    %{
      type: "series",
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      backdrop: List.first(series.backdrop_path || []),
      poster: series.cover,
      plot: series.plot,
      rating: series.rating,
      genre: series.genre
    }
  end

  defp render_featured(_), do: nil

  defp render_movie_list(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      poster: movie.stream_icon,
      rating: movie.rating,
      genre: movie.genre,
      duration: movie.duration
    }
  end

  defp render_movie_detail(movie) do
    stream_url = build_proxied_stream_url(Movie.stream_url(movie, movie.provider))

    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      poster: movie.stream_icon,
      backdrop: movie.backdrop_path,
      images: movie.images,
      rating: movie.rating,
      genre: movie.genre,
      plot: movie.plot,
      cast: movie.cast,
      director: movie.director,
      duration: movie.duration,
      duration_secs: movie.duration_secs,
      stream_url: stream_url,
      youtube_trailer: movie.youtube_trailer,
      content_rating: movie.content_rating,
      tagline: movie.tagline,
      tmdb_id: movie.tmdb_id,
      imdb_id: movie.imdb_id
    }
  end

  defp render_series_list(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      poster: series.cover,
      rating: series.rating,
      genre: series.genre,
      season_count: series.season_count,
      episode_count: series.episode_count
    }
  end

  defp render_series_detail(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      poster: series.cover,
      backdrop: series.backdrop_path,
      images: series.images,
      rating: series.rating,
      genre: series.genre,
      plot: series.plot,
      cast: series.cast,
      director: series.director,
      youtube_trailer: series.youtube_trailer,
      content_rating: series.content_rating,
      tagline: series.tagline,
      tmdb_id: series.tmdb_id,
      season_count: series.season_count,
      episode_count: series.episode_count,
      seasons: Enum.map(series.seasons || [], &render_season/1)
    }
  end

  defp render_season(season) do
    %{
      id: season.id,
      season_number: season.season_number,
      name: season.name,
      cover: season.cover,
      air_date: season.air_date,
      overview: season.overview,
      episode_count: season.episode_count,
      episodes: Enum.map(season.episodes || [], &render_episode_list/1)
    }
  end

  defp render_episode_list(episode) do
    %{
      id: episode.id,
      episode_num: episode.episode_num,
      title: episode.title || episode.name,
      plot: episode.plot,
      still: episode.still_path || episode.cover,
      duration: episode.duration,
      duration_secs: episode.duration_secs,
      air_date: episode.air_date
    }
  end

  defp render_episode_detail(episode) do
    provider = episode.season.series.provider
    stream_url = build_proxied_stream_url(Episode.stream_url(episode, provider))

    series = episode.season.series
    season = episode.season

    %{
      id: episode.id,
      episode_num: episode.episode_num,
      title: episode.title || episode.name,
      plot: episode.plot,
      still: episode.still_path || episode.cover,
      duration: episode.duration,
      duration_secs: episode.duration_secs,
      air_date: episode.air_date,
      rating: episode.rating,
      stream_url: stream_url,
      series: %{
        id: series.id,
        name: series.name,
        poster: series.cover
      },
      season: %{
        id: season.id,
        season_number: season.season_number,
        name: season.name
      }
    }
  end

  defp render_channel_list(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: channel.stream_icon,
      epg_channel_id: channel.epg_channel_id
    }
  end

  defp render_channel_detail(channel) do
    stream_url = build_proxied_stream_url(LiveChannel.stream_url(channel, channel.provider))

    %{
      id: channel.id,
      name: channel.name,
      icon: channel.stream_icon,
      epg_channel_id: channel.epg_channel_id,
      stream_url: stream_url,
      tv_archive: channel.tv_archive,
      tv_archive_duration: channel.tv_archive_duration
    }
  end

  defp render_category(category) do
    %{
      id: category.id,
      name: category.name,
      type: category.type
    }
  end

  defp build_proxied_stream_url(original_url) do
    encoded = Base.url_encode64(original_url, padding: false)
    "/api/stream/proxy?url=#{encoded}"
  end
end
