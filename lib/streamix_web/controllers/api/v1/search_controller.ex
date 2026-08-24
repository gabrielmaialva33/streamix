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

  import StreamixWeb.Helpers.Params,
    only: [bounded_float: 4, bounded_integer: 4, parse_positive_integer: 1]

  alias Streamix.AI
  alias Streamix.Helpers
  alias StreamixWeb.Api.V1.Response

  @doc """
  GET /api/v1/search/movies?q=query
  Semantic search for movies using natural language.
  """
  def movies(conn, %{"q" => query}) when is_binary(query) do
    case normalize_query(query) do
      normalized when byte_size(normalized) >= 2 -> search_movies(conn, normalized)
      normalized -> json(conn, %{movies: [], query: normalized, semantic: false})
    end
  end

  def movies(conn, _params) do
    json(conn, %{movies: [], query: nil, semantic: false})
  end

  defp search_movies(conn, query) do
    if AI.semantic_search_available?() do
      limit = result_limit(conn.params, 20)

      opts = [
        limit: candidate_limit(limit),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case AI.semantic_search(query, :movies, opts) do
        {:ok, results} ->
          movies = enrich_movie_results(results) |> Enum.take(limit)
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

  @doc """
  GET /api/v1/search/series?q=query
  Semantic search for series using natural language.
  """
  def series(conn, %{"q" => query}) when is_binary(query) do
    case normalize_query(query) do
      normalized when byte_size(normalized) >= 2 -> search_series(conn, normalized)
      normalized -> json(conn, %{series: [], query: normalized, semantic: false})
    end
  end

  def series(conn, _params) do
    json(conn, %{series: [], query: nil, semantic: false})
  end

  defp search_series(conn, query) do
    if AI.semantic_search_available?() do
      limit = result_limit(conn.params, 20)

      opts = [
        limit: candidate_limit(limit),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case AI.semantic_search(query, :series, opts) do
        {:ok, results} ->
          series = enrich_series_results(results) |> Enum.take(limit)
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

  @doc """
  GET /api/v1/search/similar/:collection/:id
  Find content similar to a given item.
  """
  def similar(conn, %{"collection" => collection, "id" => id}) do
    with {:ok, collection_atom} <- parse_collection(collection),
         {:ok, content_id} <- parse_positive_integer(id) do
      limit = result_limit(conn.params, 10)
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
    with true <- public_source?(collection_atom, content_id),
         {:ok, results} <-
           AI.similar_content(content_id, collection_atom, limit: candidate_limit(limit)) do
      items = enrich_results(results, collection_atom) |> Enum.take(limit)
      json(conn, %{items: items, source_id: content_id, collection: collection})
    else
      false ->
        Response.error(
          conn,
          :not_found,
          "content_not_indexed",
          "Content not indexed yet"
        )

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
        Map.take(stats, [:movies, :series])
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
    results = normalize_result_ids(results)
    ids = Enum.map(results, & &1.id)
    movies = Streamix.Catalog.list_public_movies_by_ids(ids, show_adult: false)
    movies_map = Map.new(movies, &{&1.id, &1})

    Enum.flat_map(results, fn result ->
      case Map.fetch(movies_map, result.id) do
        {:ok, movie} -> [merge_movie(result, movie)]
        :error -> []
      end
    end)
  end

  defp enrich_series_results(results) do
    results = normalize_result_ids(results)
    ids = Enum.map(results, & &1.id)
    series = Streamix.Catalog.list_public_series_by_ids(ids, show_adult: false)
    series_map = Map.new(series, &{&1.id, &1})

    Enum.flat_map(results, fn result ->
      case Map.fetch(series_map, result.id) do
        {:ok, series} -> [merge_series(result, series)]
        :error -> []
      end
    end)
  end

  defp enrich_results(results, :movies), do: enrich_movie_results(results)
  defp enrich_results(results, :series), do: enrich_series_results(results)

  defp parse_collection("movies"), do: {:ok, :movies}
  defp parse_collection("series"), do: {:ok, :series}
  defp parse_collection(_), do: :invalid_collection

  defp public_source?(:movies, id), do: Streamix.Catalog.list_public_movies_by_ids([id]) != []
  defp public_source?(:series, id), do: Streamix.Catalog.list_public_series_by_ids([id]) != []

  defp merge_movie(result, movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: proxy_image(movie.stream_icon),
      backdrop: proxy_image(Streamix.Catalog.backdrop_urls(movie)),
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
      backdrop: proxy_image(Streamix.Catalog.backdrop_urls(series)),
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
    movies = Streamix.Search.search_public_movies(query, limit: result_limit(conn.params, 20))

    json(conn, %{
      movies: Enum.map(movies, &serialize_movie/1),
      query: query,
      semantic: false
    })
  end

  defp fallback_search(conn, query, :series) do
    series = Streamix.Search.search_public_series(query, limit: result_limit(conn.params, 20))

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

  defp result_limit(params, default), do: bounded_integer(params["limit"], default, 1, 50)
  defp candidate_limit(limit), do: min(limit * 4, 200)

  defp parse_float(value, default), do: bounded_float(value, default, 0.0, 1.0)

  defp normalize_query(query) do
    query
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp normalize_result_ids(results) do
    Enum.flat_map(results, fn
      %{id: id} = result ->
        case parse_positive_integer(id) do
          {:ok, normalized_id} -> [Map.put(result, :id, normalized_id)]
          :error -> []
        end

      _result ->
        []
    end)
  end
end
