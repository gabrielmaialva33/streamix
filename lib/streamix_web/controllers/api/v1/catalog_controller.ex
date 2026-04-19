defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  Public catalog API for TV app and other clients.
  Provides read-only access to content from public/global providers.

  Stream URLs are returned as proxy URLs with signed tokens.
  Credentials are never exposed to clients.
  """
  use StreamixWeb, :controller

  alias Streamix.Helpers
  alias Streamix.Iptv
  alias Streamix.Iptv.{Movie, Series}
  alias StreamixWeb.Helpers.ResizeUrl
  alias StreamixWeb.StreamToken

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
      {:movie, movie} -> build_featured_movie(movie)
      {:series, series} -> build_featured_series(series)
      nil -> nil
    end
  end

  defp build_featured_movie(movie) do
    poster = proxy_image(movie.stream_icon)
    hero_backdrop = List.first(Movie.backdrop_urls(movie) || []) || movie.stream_icon

    %{
      id: movie.id,
      type: "movie",
      title: movie.title || movie.name,
      name: movie.name,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      plot: movie.plot,
      poster: poster,
      backdrop: featured_backdrop(Movie.backdrop_urls(movie), poster)
    }
    |> with_image_variants(movie.stream_icon, hero_backdrop)
  end

  defp build_featured_series(series) do
    poster = proxy_image(series.cover)
    hero_backdrop = List.first(Series.backdrop_urls(series) || []) || series.cover

    %{
      id: series.id,
      type: "series",
      title: series.title || series.name,
      name: series.name,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      plot: series.plot,
      poster: poster,
      backdrop: featured_backdrop(Series.backdrop_urls(series), poster)
    }
    |> with_image_variants(series.cover, hero_backdrop)
  end

  # Netflix-style responsive images: hand clients a stable set of
  # pre-sized variants so the TV renderer can pick the right one for
  # the viewport without shipping a CDN wrapper in JS. The raw URLs stay
  # in `poster` / `backdrop` for legacy clients.
  @poster_widths [240, 480, 720]
  @backdrop_widths [720, 1280]

  defp with_image_variants(payload, poster_url, backdrop_url) do
    payload
    |> Map.merge(ResizeUrl.flatten("poster", poster_url, @poster_widths))
    |> Map.merge(ResizeUrl.flatten("backdrop", backdrop_url, @backdrop_widths))
  end

  # Always returns a non-empty list when a poster exists, so hero rendering
  # never has to deal with null. Callers can prefer index 0 for the hero bg.
  defp featured_backdrop([], nil), do: []
  defp featured_backdrop([], poster), do: [poster]

  defp featured_backdrop(urls, _poster) when is_list(urls) do
    proxied = proxy_image(urls)
    if is_list(proxied), do: Enum.reject(proxied, &is_nil/1), else: [proxied]
  end

  @doc """
  GET /api/v1/catalog/movies
  Returns paginated list of movies from public/global providers.
  Query params: limit, offset, category_id, search, sort.

  Sort values: rating_desc | created_desc | year_desc | name_asc.
  """
  def movies(conn, params) do
    provider = Iptv.get_global_provider()

    if provider do
      opts = [
        limit: min(parse_int(params["limit"], 20), 100),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"],
        sort: normalize_sort(params["sort"])
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
  Query params: limit, offset, category_id, search, sort.

  Sort values: rating_desc | created_desc | year_desc | name_asc.
  """
  def series(conn, params) do
    provider = Iptv.get_global_provider()

    if provider do
      opts = [
        limit: min(parse_int(params["limit"], 20), 100),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"],
        sort: normalize_sort(params["sort"])
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
      # Accept both :limit and :per_page (REST convention) so older TV clients
      # that send per_page don't silently fall back to the default 30.
      requested_limit = params["limit"] || params["per_page"]

      opts = [
        limit: min(parse_int(requested_limit, 30), 100),
        offset: parse_int(params["offset"], 0),
        category_id: parse_int(params["category_id"], nil),
        search: params["search"]
      ]

      channels = Iptv.list_live_channels(provider.id, opts)
      # Pass the same filter opts to count — otherwise `total` is the whole
      # provider's channel count and `has_more` is stuck on `true` for every
      # category page that has fewer items than the full catalog.
      total = Iptv.count_live_channels(provider.id, opts)

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
    # Map API types to database types (movie -> vod, series -> series, live -> live)
    type =
      case params["type"] do
        "movie" -> "vod"
        "movies" -> "vod"
        nil -> "vod"
        other -> other
      end

    if provider do
      categories = Iptv.list_categories(provider.id, type)

      json(
        conn,
        Enum.map(categories, fn cat ->
          %{
            id: cat.id,
            name: clean_category_name(cat.name),
            type: cat.type
          }
        end)
      )
    else
      json(conn, [])
    end
  end

  # Clean category names for TV app display
  # Removes special unicode characters, accents and normalizes prefixes
  defp clean_category_name(name) when is_binary(name) do
    name
    |> String.replace(~r/『』/, " - ")
    |> remove_accents()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_category_name(name), do: name

  # Remove accented characters for TV font compatibility
  defp remove_accents(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  @doc """
  GET /api/v1/catalog/search?q=query
  Searches across movies, series, and channels.
  """
  def search(conn, %{"q" => query}) when is_binary(query) and byte_size(query) >= 2 do
    query = String.slice(query, 0, 200)
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

  @doc """
  GET /api/v1/catalog/home?limit=20
  Returns every section the TV home screen needs in a single round
  trip: featured hero + trending/recent/top-rated for movies, trending
  for series.

  The sub-queries run concurrently in a `Task.async_stream` so the
  endpoint's wall-clock latency is roughly `max(subquery)` rather than
  their sum — ~80-120ms on a warm cache vs the 350-500ms a five-request
  fan-out costs the TV app today.

  Accepts the same `?limit=` each underlying section respects;
  defaults to 20 (capped at 50).
  """
  def home(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)

    sections = [
      featured: fn -> build_featured_content() end,
      trending_movies: fn -> Iptv.list_trending("movie", limit: limit) end,
      recent_movies: fn -> Iptv.list_recent("movie", limit: limit) end,
      top_rated_movies: fn -> Iptv.list_top_rated("movie", limit: limit) end,
      trending_series: fn -> Iptv.list_trending("series", limit: limit) end
    ]

    # `ordered: false` lets results come in as they finish — we recombine
    # by key. `:kill_task` on timeout means a single slow section can't
    # stall the rest of the payload; a missing key just won't appear in
    # the response body.
    results =
      sections
      |> Task.async_stream(
        fn {key, fun} -> {key, fun.()} end,
        max_concurrency: length(sections),
        timeout: :timer.seconds(10),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, value}}, acc -> Map.put(acc, key, value)
        {:exit, _reason}, acc -> acc
      end)

    json(conn, %{
      featured: Map.get(results, :featured),
      trending_movies: serialize_items("movie", results[:trending_movies] || []),
      recent_movies: serialize_items("movie", results[:recent_movies] || []),
      top_rated_movies: serialize_items("movie", results[:top_rated_movies] || []),
      trending_series: serialize_items("series", results[:trending_series] || [])
    })
  end

  @doc """
  GET /api/v1/catalog/trending?type=movie|series&limit=20
  Returns content trending by recent watch activity.
  Falls back to new releases / high-rated when there is no watch history.
  """
  def trending(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)
    type = normalize_content_type(params["type"])
    items = Iptv.list_trending(type, limit: limit)
    json(conn, %{type: type, items: serialize_items(type, items)})
  end

  @doc """
  GET /api/v1/catalog/recent?type=movie|series&limit=20
  Returns most recently added content from public/global providers.
  """
  def recent(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)
    type = normalize_content_type(params["type"])
    items = Iptv.list_recent(type, limit: limit)
    json(conn, %{type: type, items: serialize_items(type, items)})
  end

  @doc """
  GET /api/v1/catalog/top-rated?type=movie|series&limit=20
  Returns highest-rated content from public/global providers.
  """
  def top_rated(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)
    type = normalize_content_type(params["type"])
    items = Iptv.list_top_rated(type, limit: limit)
    json(conn, %{type: type, items: serialize_items(type, items)})
  end

  defp normalize_content_type("series"), do: "series"
  defp normalize_content_type(_), do: "movie"

  defp normalize_sort(nil), do: nil
  defp normalize_sort(""), do: nil

  defp normalize_sort(value)
       when value in [
              "rating_desc",
              "created_desc",
              "year_desc",
              "name_asc"
            ],
       do: value

  defp normalize_sort(_), do: nil

  defp serialize_items("series", items), do: Enum.map(items, &serialize_series/1)
  defp serialize_items(_, items), do: Enum.map(items, &serialize_movie/1)

  # Serializers
  defp serialize_movie(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: proxy_image(movie.stream_icon),
      duration: format_duration(movie.duration_secs)
    }
  end

  defp serialize_movie_detail(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      plot: movie.plot,
      cast: Helpers.cast_names(movie.credits),
      director: Helpers.director_names(movie.credits),
      duration: format_duration(movie.duration_secs),
      content_rating: movie.content_rating,
      tagline: movie.tagline,
      poster: proxy_image(movie.stream_icon),
      backdrop: proxy_image(Movie.backdrop_urls(movie)),
      youtube_trailer: movie.youtube_trailer,
      stream_url: build_stream_url(movie),
      browser_stream_url: build_browser_stream_url(movie)
    }
    |> with_image_variants(movie.stream_icon, List.first(Movie.backdrop_urls(movie) || []))
  end

  defp serialize_series(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      poster: proxy_image(series.cover)
    }
  end

  defp serialize_series_detail(series) do
    seasons = series.seasons || []

    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      plot: series.plot,
      cast: Helpers.cast_names(series.credits),
      director: Helpers.director_names(series.credits),
      poster: proxy_image(series.cover),
      backdrop: proxy_image(Series.backdrop_urls(series)),
      season_count: length(seasons),
      episode_count: Enum.sum(Enum.map(seasons, fn s -> length(s.episodes || []) end)),
      seasons: Enum.map(seasons, &serialize_season/1)
    }
    |> with_image_variants(series.cover, List.first(Series.backdrop_urls(series) || []))
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
      still: proxy_image(episode.still_path),
      duration: format_duration(episode.duration_secs),
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
      still: proxy_image(episode.still_path),
      duration: format_duration(episode.duration_secs),
      air_date: episode.air_date,
      series_id: series.id,
      series_name: series.name,
      stream_url: build_episode_stream_url(episode, series),
      browser_stream_url: build_browser_episode_url(episode)
    }
  end

  defp serialize_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: proxy_image(channel.stream_icon)
    }
  end

  defp serialize_channel_detail(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: proxy_image(channel.stream_icon),
      stream_url: build_channel_stream_url(channel),
      browser_stream_url: build_browser_channel_url(channel)
    }
  end

  @doc """
  Returns stream URL for a movie.
  """
  def movie_stream(conn, %{"id" => id}) do
    case Iptv.get_movie_for_stream(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Movie not found"})

      movie ->
        json(conn, %{stream_url: build_stream_url(movie)})
    end
  end

  @doc """
  Returns stream URL for an episode.
  """
  def episode_stream(conn, %{"id" => id}) do
    case Iptv.get_episode_for_stream(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Episode not found"})

      episode ->
        json(conn, %{stream_url: build_episode_stream_url(episode, episode.season.series)})
    end
  end

  @doc """
  Returns stream URL for a channel.
  """
  def channel_stream(conn, %{"id" => id}) do
    case Iptv.get_live_channel_for_stream(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Channel not found"})

      channel ->
        json(conn, %{stream_url: build_channel_stream_url(channel)})
    end
  end

  # Stream URL Builders - Now using signed tokens for security
  # Credentials are never exposed to clients
  #
  # We provide two URL types:
  # - stream_url: Token-based proxy for AVPlay on Tizen (works with any format)
  # - browser_stream_url: Pannxs proxy for browser testing (handles CORS)
  #
  # All catalog endpoints are behind the `:api_v1` pipeline which runs
  # `StreamixWeb.Plugs.ApiKeyAuth` — so by the time we reach any action in
  # this controller, the caller has proved integration-level authorization.
  # We embed that authorization inside the signed token so the stream proxy
  # can bypass the subscription check even when the URL is later fetched
  # through an intermediate proxy (e.g. source.mahina.cloud) that doesn't
  # forward the `X-API-Key` header.

  @sign_opts [bypass_subscription: true]

  defp build_stream_url(movie) do
    token = StreamToken.sign_movie(movie.id, nil, @sign_opts)
    build_token_proxy_url(token)
  end

  defp build_episode_stream_url(episode, _series) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)
    build_token_proxy_url(token)
  end

  defp build_channel_stream_url(channel) do
    token = StreamToken.sign_channel(channel.id, nil, @sign_opts)
    build_token_proxy_url(token)
  end

  defp build_token_proxy_url(token) do
    base_url = StreamixWeb.Endpoint.url()
    "#{base_url}/api/stream/proxy?token=#{URI.encode_www_form(token)}"
  end

  # Browser-compatible proxy URLs using signed tokens
  # Credentials are never exposed — the token is resolved server-side.
  # Tokens embed the bypass_subscription flag (see @sign_opts above), so the
  # stream proxy does not require X-API-Key even when the browser goes
  # through source.mahina.cloud which strips request headers.
  defp build_browser_stream_url(movie) do
    token = StreamToken.sign_movie(movie.id, nil, @sign_opts)
    build_browser_token_proxy_url(token)
  end

  defp build_browser_episode_url(episode) do
    token = StreamToken.sign_episode(episode.id, nil, @sign_opts)
    build_browser_token_proxy_url(token)
  end

  defp build_browser_channel_url(channel) do
    token = StreamToken.sign_channel(channel.id, nil, @sign_opts)
    build_browser_token_proxy_url(token)
  end

  defp build_browser_token_proxy_url(token) do
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")
    base_url = StreamixWeb.Endpoint.url()
    token_url = "#{base_url}/api/stream/proxy?token=#{URI.encode_www_form(token)}"
    "#{proxy_base}/proxy?url=#{URI.encode_www_form(token_url)}"
  end

  # Image proxy helper - proxies TMDB images through our Cloudflare tunnel
  # Adds cache-busting version to force CDN refresh after config changes
  @image_cache_version "v2"

  defp proxy_image(nil), do: nil
  defp proxy_image(""), do: nil
  defp proxy_image(urls) when is_list(urls), do: Enum.map(urls, &proxy_image/1)

  defp proxy_image(url) when is_binary(url) do
    tmdb = Application.get_env(:streamix, :tmdb_proxy_url, "https://tmdb.mahina.cloud")
    imgmxa = Application.get_env(:streamix, :imgmxa_proxy_url, "https://imgmxa.mahina.cloud")

    url
    |> String.replace("https://image.tmdb.org", tmdb)
    |> String.replace("https://imgmxa.net", imgmxa)
    |> String.replace("http://imgmxa.net", imgmxa)
    |> add_cache_buster()
  end

  defp add_cache_buster(url) do
    if String.contains?(url, "?") do
      "#{url}&_v=#{@image_cache_version}"
    else
      "#{url}?_v=#{@image_cache_version}"
    end
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

  defp format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    mins = rem(total_minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}min"
    end
  end

  defp format_duration(_), do: nil
end
