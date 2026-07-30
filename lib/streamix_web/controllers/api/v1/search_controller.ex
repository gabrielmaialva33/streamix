defmodule StreamixWeb.Api.V1.SearchController do
  @moduledoc """
  Semantic search API controller.

  Provides AI-powered natural language search using Gemini embeddings
  and Qdrant vector similarity search.

  ## Endpoints

  - GET /api/v1/search/movies?q=query - Search movies semantically
  - GET /api/v1/search/series?q=query - Search series semantically
  - GET /api/v1/search/similar/:collection/:id - Find similar content

  ## Features

  - Natural language queries ("action movies with car chases")
  - Semantic understanding (finds related content, not just keyword matches)
  - Similar content recommendations
  """
  use StreamixWeb, :controller

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.AI
  alias Streamix.Helpers
  alias Streamix.Iptv
  alias StreamixWeb.Api.V1.Response

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
  GET /api/v1/search/movies?q=query
  Semantic search for movies using natural language.
  """
  def movies(conn, %{"q" => query}) when is_binary(query) and byte_size(query) >= 2 do
    if AI.semantic_search_available?() do
      opts = [
        limit: parse_int(conn.params["limit"], 20),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case AI.semantic_search(query, :movies, opts) do
        {:ok, results} ->
          movies = enrich_movie_results(results)
          json(conn, %{movies: movies, query: query, semantic: true})

        {:error, reason} ->
          Response.internal_error(
            conn,
            :service_unavailable,
            "search_failed",
            "Search failed",
            reason
          )
      end
    else
      fallback_search(conn, query, :movies)
    end
  end

  def movies(conn, _params) do
    json(conn, %{movies: [], query: nil, semantic: false})
  end

  @doc """
  GET /api/v1/search/series?q=query
  Semantic search for series using natural language.
  """
  def series(conn, %{"q" => query}) when is_binary(query) and byte_size(query) >= 2 do
    if AI.semantic_search_available?() do
      opts = [
        limit: parse_int(conn.params["limit"], 20),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case AI.semantic_search(query, :series, opts) do
        {:ok, results} ->
          series = enrich_series_results(results)
          json(conn, %{series: series, query: query, semantic: true})

        {:error, reason} ->
          Response.internal_error(
            conn,
            :service_unavailable,
            "search_failed",
            "Search failed",
            reason
          )
      end
    else
      fallback_search(conn, query, :series)
    end
  end

  def series(conn, _params) do
    json(conn, %{series: [], query: nil, semantic: false})
  end

  @doc """
  GET /api/v1/search/similar/:collection/:id
  Find content similar to a given item.
  """
  def similar(conn, %{"collection" => collection, "id" => id}) do
    with {:ok, collection_atom} <- parse_collection(collection),
         {:ok, content_id} <- parse_positive_integer(id) do
      limit = parse_int(conn.params["limit"], 10)
      similar_results(conn, collection, collection_atom, content_id, limit)
    else
      :invalid_collection ->
        Response.error(conn, :bad_request, "invalid_collection", "Invalid collection")

      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid content id")
    end
  end

  defp similar_results(conn, collection, collection_atom, content_id, limit) do
    if AI.semantic_search_available?() do
      search_similar(conn, collection, collection_atom, content_id, limit)
    else
      Response.error(
        conn,
        :service_unavailable,
        "semantic_search_unavailable",
        "Semantic search not available"
      )
    end
  end

  defp search_similar(conn, collection, collection_atom, content_id, limit) do
    case AI.similar_content(content_id, collection_atom, limit: limit) do
      {:ok, results} ->
        items = enrich_results(results, collection_atom)
        json(conn, %{items: items, source_id: content_id, collection: collection})

      {:error, :not_found} ->
        Response.error(
          conn,
          :not_found,
          "content_not_indexed",
          "Content not indexed yet"
        )

      {:error, reason} ->
        Response.internal_error(
          conn,
          :service_unavailable,
          "search_failed",
          "Search failed",
          reason
        )
    end
  end

  @doc """
  GET /api/v1/search/status
  Returns semantic search availability and stats.
  """
  def status(conn, _params) do
    available = AI.semantic_search_available?()

    stats =
      if available do
        {:ok, stats} = AI.semantic_search_stats()
        stats
      else
        %{}
      end

    json(conn, %{
      available: available,
      stats: stats
    })
  end

  @doc """
  GET /api/v1/search/info
  Returns detailed semantic search system info.
  """
  def info(conn, _params) do
    json(conn, AI.semantic_search_info())
  end

  # Private functions

  defp enrich_movie_results(results) do
    ids = Enum.map(results, & &1.id)
    movies = Iptv.get_movies_by_ids(ids)
    movies_map = Map.new(movies, &{&1.id, &1})

    Enum.map(results, fn result ->
      case Map.get(movies_map, result.id) do
        nil -> result
        movie -> merge_movie(result, movie)
      end
    end)
  end

  defp enrich_series_results(results) do
    ids = Enum.map(results, & &1.id)
    series = Iptv.get_series_by_ids(ids)
    series_map = Map.new(series, &{&1.id, &1})

    Enum.map(results, fn result ->
      case Map.get(series_map, result.id) do
        nil -> result
        s -> merge_series(result, s)
      end
    end)
  end

  defp enrich_results(results, :movies), do: enrich_movie_results(results)
  defp enrich_results(results, :series), do: enrich_series_results(results)

  defp parse_collection("movies"), do: {:ok, :movies}
  defp parse_collection("series"), do: {:ok, :series}
  defp parse_collection(_), do: :invalid_collection

  defp merge_movie(result, movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: proxy_image(movie.stream_icon),
      backdrop: proxy_image(Iptv.backdrop_urls(movie)),
      plot: movie.plot,
      score: result.score
    }
  end

  defp merge_series(result, series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      poster: proxy_image(series.cover),
      backdrop: proxy_image(Iptv.backdrop_urls(series)),
      plot: series.plot,
      score: result.score
    }
  end

  defp proxy_image(nil), do: nil
  defp proxy_image(""), do: nil
  defp proxy_image(urls) when is_list(urls), do: Enum.map(urls, &proxy_image/1)

  defp proxy_image(url) when is_binary(url) do
    alias StreamixWeb.Helpers.ImageProxy
    ImageProxy.proxy(url)
  end

  defp fallback_search(conn, query, :movies) do
    movies = Iptv.search_public_movies(query, limit: 20)

    json(conn, %{
      movies: Enum.map(movies, &serialize_movie/1),
      query: query,
      semantic: false
    })
  end

  defp fallback_search(conn, query, :series) do
    series = Iptv.search_public_series(query, limit: 20)

    json(conn, %{
      series: Enum.map(series, &serialize_series/1),
      query: query,
      semantic: false
    })
  end

  defp serialize_movie(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: movie.stream_icon
    }
  end

  defp serialize_series(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      poster: series.cover
    }
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

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(_, default), do: default
end
