defmodule Streamix.AI.Qdrant do
  @moduledoc """
  Client for Qdrant vector database.

  Manages collections and vector search operations for semantic search
  and content recommendations.

  ## Collections

  - `movies` - Movie embeddings with metadata
  - `series` - Series embeddings with metadata
  - `animes` - Anime embeddings with metadata

  ## Configuration

  Set the following environment variables:
  - `QDRANT_URL` - Qdrant server URL (default: http://localhost:6333)
  - `QDRANT_API_KEY` - Optional API key for authentication
  """

  require Logger

  alias Streamix.AI.Embeddings

  @default_url "http://localhost:6333"
  @collections ~w(movies series animes)

  # Public API

  @doc """
  Checks if Qdrant is configured and reachable.
  """
  def enabled? do
    case health_check() do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Performs a health check on the Qdrant server.
  Uses the root endpoint which returns server info.
  """
  def health_check do
    case Req.get("#{base_url()}/", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: %{"version" => _}}} -> {:ok, :healthy}
      {:ok, %Req.Response{status: 200}} -> {:ok, :healthy}
      {:ok, %Req.Response{status: status}} -> {:error, {:unhealthy, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensures all required collections exist with proper configuration.
  """
  def setup_collections do
    Enum.each(@collections, &ensure_collection/1)
    :ok
  end

  @doc """
  Upserts a vector point into a collection.

  ## Parameters
  - `collection` - Collection name (movies, series, animes)
  - `id` - Unique point ID (content ID)
  - `vector` - Embedding vector
  - `payload` - Metadata (title, year, provider_id, etc.)
  """
  def upsert_point(collection, id, vector, payload) do
    url = "#{base_url()}/collections/#{collection}/points"

    body =
      Jason.encode!(%{
        points: [
          %{
            id: id,
            vector: vector,
            payload: payload
          }
        ]
      })

    case req_put(url, body) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, id}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Qdrant] Upsert failed #{status}: #{inspect(body)}")
        {:error, {:upsert_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upserts multiple vector points in batch.
  """
  def upsert_points(collection, points) when is_list(points) do
    url = "#{base_url()}/collections/#{collection}/points"

    formatted_points =
      Enum.map(points, fn {id, vector, payload} ->
        %{id: id, vector: vector, payload: payload}
      end)

    body = Jason.encode!(%{points: formatted_points})

    case req_put(url, body) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, length(points)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Qdrant] Batch upsert failed #{status}: #{inspect(body)}")
        {:error, {:upsert_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Searches for similar vectors in a collection.

  ## Parameters
  - `collection` - Collection to search
  - `vector` - Query vector
  - `opts` - Options:
    - `:limit` - Max results (default: 10)
    - `:score_threshold` - Minimum similarity score (default: 0.7)
    - `:filter` - Qdrant filter for payload fields

  ## Returns
  List of `%{id: id, score: float, payload: map}` sorted by similarity.
  """
  def search(collection, vector, opts \\ []) do
    url = "#{base_url()}/collections/#{collection}/points/search"

    limit = Keyword.get(opts, :limit, 10)
    score_threshold = Keyword.get(opts, :score_threshold, 0.7)
    filter = Keyword.get(opts, :filter)

    body =
      %{
        vector: vector,
        limit: limit,
        score_threshold: score_threshold,
        with_payload: true
      }
      |> maybe_add_filter(filter)
      |> Jason.encode!()

    case req_post(url, body) do
      {:ok, %Req.Response{status: 200, body: %{"result" => results}}} ->
        formatted =
          Enum.map(results, fn r ->
            %{
              id: r["id"],
              score: r["score"],
              payload: r["payload"]
            }
          end)

        {:ok, formatted}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Qdrant] Search failed #{status}: #{inspect(body)}")
        {:error, {:search_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Searches for similar content using text query.

  Generates embedding from query text and searches the collection.
  Uses configured embedding provider with automatic fallback.
  """
  def search_by_text(collection, query_text, opts \\ []) do
    case Embeddings.embed(query_text) do
      {:ok, vector} ->
        search(collection, vector, opts)

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  @doc """
  Finds content similar to a given content ID.

  Retrieves the vector for the given ID and searches for similar.
  """
  def find_similar(collection, content_id, opts \\ []) do
    case get_point(collection, content_id) do
      {:ok, %{vector: vector}} ->
        # Exclude the source content from results
        filter = %{
          must_not: [%{has_id: [content_id]}]
        }

        opts = Keyword.put(opts, :filter, filter)
        search(collection, vector, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a single point by ID.
  """
  def get_point(collection, id) do
    url = "#{base_url()}/collections/#{collection}/points/#{id}"

    case req_get(url) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok,
         %{
           id: result["id"],
           vector: result["vector"],
           payload: result["payload"]
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Qdrant] Get point failed #{status}: #{inspect(body)}")
        {:error, {:get_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a point from a collection.
  """
  def delete_point(collection, id) do
    url = "#{base_url()}/collections/#{collection}/points/delete"

    body = Jason.encode!(%{points: [id]})

    case req_post(url, body) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:delete_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns collection info including vector count.
  """
  def collection_info(collection) do
    url = "#{base_url()}/collections/#{collection}"

    case req_get(url) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok,
         %{
           vectors_count: result["vectors_count"],
           points_count: result["points_count"],
           status: result["status"]
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp ensure_collection(name) do
    url = "#{base_url()}/collections/#{name}"

    case req_get(url) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.debug("[Qdrant] Collection #{name} exists")
        :ok

      {:ok, %Req.Response{status: 404}} ->
        create_collection(name)

      {:error, reason} ->
        Logger.error("[Qdrant] Failed to check collection #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_collection(name) do
    url = "#{base_url()}/collections/#{name}"

    body =
      Jason.encode!(%{
        vectors: %{
          size: Embeddings.embedding_dimensions(),
          distance: "Cosine"
        },
        optimizers_config: %{
          indexing_threshold: 10_000
        }
      })

    case req_put(url, body) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.info("[Qdrant] Created collection #{name}")
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Qdrant] Failed to create collection #{name}: #{status} - #{inspect(body)}")
        {:error, {:create_failed, status}}

      {:error, reason} ->
        Logger.error("[Qdrant] Failed to create collection #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_add_filter(body, nil), do: body
  defp maybe_add_filter(body, filter), do: Map.put(body, :filter, filter)

  defp base_url do
    Application.get_env(:streamix, :qdrant, [])[:url] ||
      System.get_env("QDRANT_URL") ||
      @default_url
  end

  defp api_key do
    Application.get_env(:streamix, :qdrant, [])[:api_key] ||
      System.get_env("QDRANT_API_KEY")
  end

  defp headers do
    base = [{"Content-Type", "application/json"}]

    case api_key() do
      nil -> base
      "" -> base
      key -> [{"api-key", key} | base]
    end
  end

  defp req_get(url) do
    Req.get(url, headers: headers(), receive_timeout: 10_000)
  end

  defp req_post(url, body) do
    Req.post(url, body: body, headers: headers(), receive_timeout: 30_000)
  end

  defp req_put(url, body) do
    Req.put(url, body: body, headers: headers(), receive_timeout: 30_000)
  end
end
