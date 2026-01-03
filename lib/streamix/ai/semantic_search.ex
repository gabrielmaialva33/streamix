defmodule Streamix.AI.SemanticSearch do
  @moduledoc """
  Semantic search and recommendations using vector embeddings.

  Provides high-level functions for:
  - Searching content by natural language queries
  - Finding similar content (recommendations)
  - Indexing content for search

  ## Usage

      # Search movies by description
      SemanticSearch.search("action movie with car chases", :movies, limit: 10)

      # Find similar content
      SemanticSearch.similar(movie_id, :movies, limit: 5)

      # Index content
      SemanticSearch.index_content(movie, :movies)
  """

  require Logger

  alias Streamix.AI.{Gemini, Qdrant}
  alias Streamix.Repo

  import Ecto.Query

  @batch_size 10
  # 40 rpm = 1.5s between requests
  @rate_limit_delay 1500

  # Public API

  @doc """
  Checks if semantic search is available.
  """
  def available? do
    Gemini.enabled?() and Qdrant.enabled?()
  end

  @doc """
  Initializes the search system (creates collections).
  """
  def setup do
    if available?() do
      Qdrant.setup_collections()
    else
      Logger.warning("[SemanticSearch] Not available - check Gemini and Qdrant config")
      {:error, :not_available}
    end
  end

  @doc """
  Searches for content using natural language query.

  ## Parameters
  - `query` - Natural language search query
  - `collection` - Collection to search (:movies, :series, :animes)
  - `opts` - Options:
    - `:limit` - Max results (default: 10)
    - `:provider_id` - Filter by provider
    - `:min_score` - Minimum similarity score (default: 0.7)

  ## Returns
  `{:ok, [%{id, score, title, year, ...}]}` or `{:error, reason}`
  """
  def search(query, collection, opts \\ []) when is_atom(collection) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.7)
    provider_id = Keyword.get(opts, :provider_id)

    filter = build_filter(provider_id: provider_id)

    search_opts = [
      limit: limit,
      score_threshold: min_score,
      filter: filter
    ]

    case Qdrant.search_by_text(to_string(collection), query, search_opts) do
      {:ok, results} ->
        formatted = format_results(results)
        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Finds content similar to a given content ID.

  ## Parameters
  - `content_id` - ID of the source content
  - `collection` - Collection (:movies, :series, :animes)
  - `opts` - Options:
    - `:limit` - Max results (default: 5)
    - `:cross_provider` - Include results from other providers (default: true)
  """
  def similar(content_id, collection, opts \\ []) when is_atom(collection) do
    limit = Keyword.get(opts, :limit, 5)

    search_opts = [limit: limit]

    case Qdrant.find_similar(to_string(collection), content_id, search_opts) do
      {:ok, results} ->
        formatted = format_results(results)
        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Indexes a single content item for search.

  ## Parameters
  - `content` - Content struct (Movie, Series, Anime) with title, description, etc.
  - `collection` - Target collection (:movies, :series, :animes)
  """
  def index_content(content, collection) when is_atom(collection) do
    content_map = content_to_map(content)

    case Gemini.embed_content(content_map) do
      {:ok, vector} ->
        payload = build_payload(content_map)
        Qdrant.upsert_point(to_string(collection), content.id, vector, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Indexes multiple content items in batch.

  Respects NVIDIA rate limits by processing in batches with delays.
  Returns the count of successfully indexed items.
  """
  def index_contents(contents, collection) when is_list(contents) and is_atom(collection) do
    contents
    |> Enum.map(&content_to_map/1)
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce({:ok, 0}, fn batch, {:ok, count} ->
      case index_batch(batch, collection) do
        {:ok, indexed} ->
          # Rate limit delay between batches
          Process.sleep(@rate_limit_delay)
          {:ok, count + indexed}

        {:error, reason} ->
          Logger.error("[SemanticSearch] Batch indexing failed: #{inspect(reason)}")
          # Continue with next batch
          {:ok, count}
      end
    end)
  end

  @doc """
  Indexes all movies from database.

  Use with caution - this can take a long time for large datasets.
  Consider using the background worker instead.
  """
  def index_all_movies(provider_id \\ nil) do
    query =
      from(m in Streamix.Iptv.Movie,
        where: not is_nil(m.title),
        select: %{
          id: m.id,
          title: m.title,
          plot: m.plot,
          year: m.year,
          genres: m.genre,
          provider_id: m.provider_id
        }
      )

    query =
      if provider_id,
        do: where(query, [m], m.provider_id == ^provider_id),
        else: query

    movies = Repo.all(query)
    Logger.info("[SemanticSearch] Indexing #{length(movies)} movies")

    index_contents(movies, :movies)
  end

  @doc """
  Indexes all series from database.
  """
  def index_all_series(provider_id \\ nil) do
    query =
      from(s in Streamix.Iptv.Series,
        where: not is_nil(s.title),
        select: %{
          id: s.id,
          title: s.title,
          plot: s.plot,
          year: s.year,
          genres: s.genre,
          provider_id: s.provider_id
        }
      )

    query =
      if provider_id,
        do: where(query, [s], s.provider_id == ^provider_id),
        else: query

    series = Repo.all(query)
    Logger.info("[SemanticSearch] Indexing #{length(series)} series")

    index_contents(series, :series)
  end

  @doc """
  Returns stats about indexed content.
  """
  def stats do
    collections = [:movies, :series, :animes]

    stats =
      Enum.map(collections, fn col ->
        case Qdrant.collection_info(to_string(col)) do
          {:ok, info} -> {col, info}
          {:error, _} -> {col, %{vectors_count: 0, status: "not_found"}}
        end
      end)
      |> Map.new()

    {:ok, stats}
  end

  # Private functions

  defp index_batch(contents, collection) do
    case Gemini.embed_contents(contents) do
      {:ok, embeddings} ->
        points =
          Enum.map(embeddings, fn {id, vector} ->
            content = Enum.find(contents, &(&1.id == id))
            payload = build_payload(content)
            {id, vector, payload}
          end)

        Qdrant.upsert_points(to_string(collection), points)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_to_map(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.take([:id, :title, :description, :plot, :year, :genre, :genres, :provider_id])
    |> normalize_genres()
  end

  defp content_to_map(map) when is_map(map), do: normalize_genres(map)

  defp normalize_genres(%{genre: genre} = map) when is_binary(genre) do
    genres = String.split(genre, ",") |> Enum.map(&String.trim/1)
    map |> Map.delete(:genre) |> Map.put(:genres, genres)
  end

  defp normalize_genres(%{genres: genres} = map) when is_binary(genres) do
    Map.put(map, :genres, String.split(genres, ",") |> Enum.map(&String.trim/1))
  end

  defp normalize_genres(map), do: map

  defp build_payload(content) do
    %{
      title: content[:title],
      year: content[:year],
      genres: content[:genres] || [],
      provider_id: content[:provider_id]
    }
  end

  defp build_filter(opts) do
    must = []

    must =
      if provider_id = opts[:provider_id] do
        [%{key: "provider_id", match: %{value: provider_id}} | must]
      else
        must
      end

    if must == [] do
      nil
    else
      %{must: must}
    end
  end

  defp format_results(results) do
    Enum.map(results, fn %{id: id, score: score, payload: payload} ->
      %{
        id: id,
        score: Float.round(score, 3),
        title: payload["title"],
        year: payload["year"],
        genres: payload["genres"] || [],
        provider_id: payload["provider_id"]
      }
    end)
  end
end
