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

  alias Streamix.AI.SemanticSearch
  alias Streamix.Iptv

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
    if SemanticSearch.available?() do
      opts = [
        limit: parse_int(conn.params["limit"], 20),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case SemanticSearch.search(query, :movies, opts) do
        {:ok, results} ->
          movies = enrich_movie_results(results)
          json(conn, %{movies: movies, query: query, semantic: true})

        {:error, reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Search failed", reason: inspect(reason)})
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
    if SemanticSearch.available?() do
      opts = [
        limit: parse_int(conn.params["limit"], 20),
        min_score: parse_float(conn.params["min_score"], 0.6)
      ]

      case SemanticSearch.search(query, :series, opts) do
        {:ok, results} ->
          series = enrich_series_results(results)
          json(conn, %{series: series, query: query, semantic: true})

        {:error, reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Search failed", reason: inspect(reason)})
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
    collection_atom = String.to_existing_atom(collection)
    content_id = String.to_integer(id)
    limit = parse_int(conn.params["limit"], 10)

    if SemanticSearch.available?() do
      case SemanticSearch.similar(content_id, collection_atom, limit: limit) do
        {:ok, results} ->
          items = enrich_results(results, collection_atom)
          json(conn, %{items: items, source_id: content_id, collection: collection})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Content not indexed yet"})

        {:error, reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Search failed", reason: inspect(reason)})
      end
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "Semantic search not available"})
    end
  rescue
    ArgumentError ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid collection"})
  end

  @doc """
  GET /api/v1/search/status
  Returns semantic search availability and stats.
  """
  def status(conn, _params) do
    available = SemanticSearch.available?()

    stats =
      if available do
        case SemanticSearch.stats() do
          {:ok, stats} -> stats
          _ -> %{}
        end
      else
        %{}
      end

    json(conn, %{
      available: available,
      stats: stats
    })
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
  defp enrich_results(results, _), do: results

  defp merge_movie(result, movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: movie.genre,
      poster: movie.stream_icon,
      backdrop: movie.backdrop_path,
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
      genre: series.genre,
      poster: series.cover,
      backdrop: series.backdrop_path,
      plot: series.plot,
      score: result.score
    }
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
      genre: movie.genre,
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
      genre: series.genre,
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
