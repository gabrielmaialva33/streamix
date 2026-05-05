defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  Public catalog API for TV app and other clients.
  Provides read-only access to content from public/global providers.

  Stream URLs are returned as proxy URLs with signed tokens.
  Credentials are never exposed to clients.

  Heavy lifting is delegated to focused collaborators:

    * `StreamixWeb.Catalog.Serializer`   — JSON payload shapes.
    * `StreamixWeb.Catalog.StreamUrls`   — signed stream / browser URLs.
    * `StreamixWeb.Catalog.ImageProxy`   — CDN image rewriting.

  This controller stays as a thin HTTP coordinator: parameter parsing,
  context calls, concurrency, and response wiring.
  """
  use StreamixWeb, :controller

  require Logger

  alias Streamix.Iptv
  alias StreamixWeb.Catalog.Serializer
  alias StreamixWeb.Catalog.StreamUrls

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
    Iptv.get_featured_content() |> Serializer.serialize_featured()
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
      total = Iptv.count_movies(provider.id, opts)

      json(conn, %{
        movies: Enum.map(movies, &Serializer.serialize_movie/1),
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
        enriched = safe_fetch(movie, &Iptv.fetch_movie_info/1)
        json(conn, Serializer.serialize_movie_detail(enriched))
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
      total = Iptv.count_series(provider.id, opts)

      json(conn, %{
        series: Enum.map(series_list, &Serializer.serialize_series/1),
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
    json(conn, Serializer.serialize_series_detail(series))
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
        enriched = safe_fetch(episode, &Iptv.fetch_episode_info/1)
        json(conn, Serializer.serialize_episode_detail(enriched))
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
        channels: Enum.map(channels, &Serializer.serialize_channel/1),
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
        json(conn, Serializer.serialize_channel_detail(channel))
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
    limit = min(parse_int(conn.query_params["limit"], 10), 20)

    # Ran concurrently so a single-round-trip search is capped at the
    # slowest of the three queries instead of their sum.
    [movies, series, channels] =
      [
        fn -> Iptv.search_public_movies(query, limit: limit) end,
        fn -> Iptv.search_public_series(query, limit: limit) end,
        fn -> Iptv.search_public_channels(query, limit: limit) end
      ]
      |> Task.async_stream(& &1.(),
        max_concurrency: 3,
        timeout: :timer.seconds(5),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, list} -> list
        {:exit, _} -> []
      end)

    json(conn, %{
      query: query,
      movies: Enum.map(movies, &Serializer.serialize_ranked_movie/1),
      series: Enum.map(series, &Serializer.serialize_ranked_series/1),
      channels: Enum.map(channels, &Serializer.serialize_ranked_channel/1)
    })
  end

  def search(conn, _params) do
    json(conn, %{query: "", movies: [], series: [], channels: []})
  end

  @doc """
  GET /api/v1/catalog/suggest?q=<query>&limit=10

  Typeahead endpoint tuned for TV remote UX: returns a flat, ranked
  list of up to `limit` items across movies + series + channels, each
  payload minimal (id / name / type / small poster). Designed to be
  under 50ms so it can fire on every keystroke without feeling laggy.

  `q` minimum length is 1 character (vs 2 for `/search`) because the
  caller is typing live.
  """
  def suggest(conn, params) do
    query = params["q"] || ""

    if byte_size(query) >= 1 do
      query = String.slice(query, 0, 100)
      limit = min(parse_int(params["limit"], 10), 20)

      # Spread the limit across the three buckets so a result set isn't
      # dominated by a single type. Up to 2× cap on each query, trimmed
      # and re-sorted by rank afterward.
      per_bucket = min(limit, 8)

      [movies, series, channels] =
        [
          fn -> Iptv.search_public_movies(query, limit: per_bucket) end,
          fn -> Iptv.search_public_series(query, limit: per_bucket) end,
          fn -> Iptv.search_public_channels(query, limit: per_bucket) end
        ]
        |> Task.async_stream(& &1.(),
          max_concurrency: 3,
          timeout: :timer.seconds(2),
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, list} -> list
          {:exit, _} -> []
        end)

      items =
        (Enum.map(movies, &Serializer.suggest_movie/1) ++
           Enum.map(series, &Serializer.suggest_series/1) ++
           Enum.map(channels, &Serializer.suggest_channel/1))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      json(conn, %{query: query, items: items})
    else
      json(conn, %{query: query, items: []})
    end
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
      trending_movies: Serializer.serialize_items("movie", results[:trending_movies] || []),
      recent_movies: Serializer.serialize_items("movie", results[:recent_movies] || []),
      top_rated_movies: Serializer.serialize_items("movie", results[:top_rated_movies] || []),
      trending_series: Serializer.serialize_items("series", results[:trending_series] || [])
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
    json(conn, %{type: type, items: Serializer.serialize_items(type, items)})
  end

  @doc """
  GET /api/v1/catalog/recent?type=movie|series&limit=20
  Returns most recently added content from public/global providers.
  """
  def recent(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)
    type = normalize_content_type(params["type"])
    items = Iptv.list_recent(type, limit: limit)
    json(conn, %{type: type, items: Serializer.serialize_items(type, items)})
  end

  @doc """
  GET /api/v1/catalog/top-rated?type=movie|series&limit=20
  Returns highest-rated content from public/global providers.
  """
  def top_rated(conn, params) do
    limit = min(parse_int(params["limit"], 20), 50)
    type = normalize_content_type(params["type"])
    items = Iptv.list_top_rated(type, limit: limit)
    json(conn, %{type: type, items: Serializer.serialize_items(type, items)})
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

  @doc """
  Returns stream URL for a movie.
  """
  def movie_stream(conn, %{"id" => id}) do
    case Iptv.get_movie_for_stream(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Movie not found"})

      movie ->
        json(conn, %{stream_url: StreamUrls.signed_movie_url(movie)})
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
        json(conn, %{stream_url: StreamUrls.signed_episode_url(episode)})
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
        json(conn, %{stream_url: StreamUrls.signed_channel_url(channel)})
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

  # Wraps an enrichment call so upstream failures (TMDB/AniList rate limits,
  # network errors, 404s) degrade to the base record instead of crashing the
  # action and returning HTTP 500 to the client.
  defp safe_fetch(content, fetcher) do
    case fetcher.(content) do
      {:ok, enriched} ->
        enriched

      {:error, reason} ->
        Logger.warning("Catalog enrichment failed: " <> inspect(reason))
        content
    end
  end
end
