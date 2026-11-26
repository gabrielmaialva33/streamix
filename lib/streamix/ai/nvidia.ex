defmodule Streamix.AI.Nvidia do
  @behaviour Streamix.AI.EmbeddingProvider

  @moduledoc """
  Client for NVIDIA NIM Embeddings API.

  Generates text embeddings using NVIDIA's models for semantic search
  and content recommendations.

  ## Configuration

  Set the following environment variables:
  - `NVIDIA_API_KEY` - Your NVIDIA NIM API key
  - `NVIDIA_EMBEDDING_MODEL` - Model to use (default: nvidia/nemotron-3.5-embed-1b)

  ## Rate Limits

  NVIDIA NIM has a rate limit of 40 requests per minute.
  Use batch processing to maximize throughput.
  """

  require Logger

  alias Streamix.AI.ContentText
  alias Streamix.SafeLog

  # 2026-06: NVIDIA migrated their embedding endpoints from the legacy
  # `ai.api.nvidia.com/v1/retrieval/nvidia/*` path (which returned a 404
  # "function not found for account" after the cutover) to the new
  # OpenAI-compatible `integrate.api.nvidia.com/v1` surface. Same response
  # shape (`data: [{index, embedding}]`) — only the URL + model id
  # namespacing changed. Embedding dimensions remain 1024.
  @base_url "https://integrate.api.nvidia.com/v1"
  @max_rate_limit_retries 5

  # 2026-11-25: the hosted nemotron-3.5 endpoint answers a share of requests
  # with 500 "service inference failed", for any input (the same text fails
  # and then succeeds a second later). Without a retry, one such answer failed
  # a whole indexing batch and three of them discarded the nightly reindex.
  # Indexing can afford to wait; a search query is on a person's request path,
  # so it gets one quick retry only.
  @server_error_retries %{"passage" => 4, "query" => 1}

  # 2026-08-25: NVIDIA retired a whole generation of embedding models on one
  # day — nv-embedqa-e5-v5, llama-3.2-nv-embedqa-1b-v2 and baai/bge-m3 all
  # answer 410 Gone. Semantic search had been degraded since, silently: the
  # index stayed healthy but every query needs a fresh embedding, so
  # `semantic_search_available?/0` went false and the UI fell back to text
  # search while the "similar titles" row quietly rendered empty.
  #
  # The default has to be a model that is actually alive, otherwise a fresh
  # deployment is broken before it starts.
  #
  # 2026-11-23: nemotron-3-embed-1b reached end of life too (410). Its
  # successor keeps the 2048-dimension vectors, so the Qdrant collections stay
  # as they are, but vectors from two models are not comparable: the index has
  # to be rebuilt (the daily IndexEmbeddingsWorker re-embeds every title).
  @default_model "nvidia/nemotron-3.5-embed-1b"

  # Dimensions are a property of the model, so they have to travel with it.
  # Leaving them as a constant while NVIDIA_EMBEDDING_MODEL was configurable
  # meant the two could silently disagree — and a model swap that keeps the
  # dimension count is precisely the failure SearchHealth documents it cannot
  # detect. Unknown models fall back to NVIDIA_EMBEDDING_DIMENSIONS.
  @model_dimensions %{
    "nvidia/nemotron-3.5-embed-1b" => 2048,
    "nvidia/nemotron-3.5-embed-8b" => 4096,
    "nvidia/nemotron-3-embed-1b" => 2048,
    "nvidia/llama-nemotron-embed-vl-1b-v2" => 2048,
    "nvidia/nv-embedqa-e5-v5" => 1024,
    "nvidia/llama-3.2-nv-embedqa-1b-v2" => 2048,
    "baai/bge-m3" => 1024
  }

  @default_dimensions 2048

  @doc """
  Returns the embedding dimensions for the configured model.
  """
  def embedding_dimensions do
    case configured_dimensions() do
      dimensions when is_integer(dimensions) and dimensions > 0 ->
        dimensions

      _other ->
        Map.get(@model_dimensions, model(), @default_dimensions)
    end
  end

  defp configured_dimensions do
    :streamix
    |> Application.get_env(:nvidia, [])
    |> Keyword.get(:embedding_dimensions)
  end

  @doc """
  Checks if NVIDIA NIM is configured and enabled.
  """
  def enabled? do
    api_key() != nil and api_key() != ""
  end

  @doc """
  Generates embeddings for a single text.

  ## Options
  - `:input_type` - "query" for search queries, "passage" for documents (default: "passage")

  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  def embed(text, opts \\ []) when is_binary(text) do
    case embed_batch([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates query embedding optimized for search.

  Uses input_type "query" which is optimized for short search queries
  in the E5 bi-encoder architecture.
  """
  def embed_query(text) when is_binary(text) do
    embed(text, input_type: "query")
  end

  @doc """
  Generates embeddings for multiple texts in a single request.

  This is more efficient than calling `embed/1` multiple times
  due to rate limits (40 rpm).

  ## Options
  - `:input_type` - "query" for search queries, "passage" for documents (default: "passage")

  Returns `{:ok, [[float]]}` or `{:error, reason}`.
  """
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    if enabled?() do
      input_type = Keyword.get(opts, :input_type, "passage")
      do_embed_batch(texts, input_type)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Generates embeddings for content (movie, series, etc).

  Combines title, description, and genres into a single text
  for embedding generation.
  """
  def embed_content(%{title: _title} = content) do
    text = ContentText.build(content)
    embed(text)
  end

  @doc """
  Generates embeddings for multiple content items.

  Returns `{:ok, [{id, [float]}]}` where each tuple contains
  the content ID and its embedding vector.
  """
  def embed_contents(contents) when is_list(contents) do
    texts = Enum.map(contents, &ContentText.build/1)

    case embed_batch(texts) do
      {:ok, embeddings} ->
        results =
          contents
          |> Enum.zip(embeddings)
          |> Enum.map(fn {content, embedding} -> {content.id, embedding} end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp do_embed_batch(texts, input_type, rate_limit_attempt \\ 0, server_error_attempt \\ 0) do
    url = "#{@base_url}/embeddings"

    body =
      Jason.encode!(%{
        input: texts,
        model: model(),
        input_type: input_type,
        encoding_format: "float",
        truncate: "END"
      })

    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    request_options =
      Keyword.merge(
        [body: body, headers: headers, receive_timeout: 30_000, retry: false],
        Application.get_env(:streamix, :nvidia, [])[:req_options] || []
      )

    max_server_error_retries = Map.get(@server_error_retries, to_string(input_type), 1)

    case Req.post(url, request_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embeddings =
          body["data"]
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, %Req.Response{status: 429}} when rate_limit_attempt < @max_rate_limit_retries ->
        delay = 2_000 * Integer.pow(2, rate_limit_attempt)
        Logger.warning("[NVIDIA] Rate limited, retrying in #{delay}ms")
        Process.sleep(delay)
        do_embed_batch(texts, input_type, rate_limit_attempt + 1, server_error_attempt)

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limit_retries_exhausted}

      {:ok, %Req.Response{status: status}}
      when status in 500..599 and server_error_attempt < max_server_error_retries ->
        delay = server_error_backoff() * Integer.pow(2, server_error_attempt)
        Logger.warning("[NVIDIA] Server error, retrying", reason: status)
        Process.sleep(delay)
        do_embed_batch(texts, input_type, rate_limit_attempt, server_error_attempt + 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[NVIDIA] API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[NVIDIA] Request failed", reason: SafeLog.redact_inspect(reason))
        {:error, {:request_failed, reason}}
    end
  end

  defp server_error_backoff do
    Application.get_env(:streamix, :nvidia, [])[:server_error_backoff_ms] || 1_000
  end

  defp api_key do
    Application.get_env(:streamix, :nvidia, [])[:api_key] ||
      System.get_env("NVIDIA_API_KEY")
  end

  @doc "The embedding model requests go to: the configured one, else the default."
  @spec model() :: String.t()
  def model do
    Application.get_env(:streamix, :nvidia, [])[:embedding_model] ||
      System.get_env("NVIDIA_EMBEDDING_MODEL") ||
      @default_model
  end
end
