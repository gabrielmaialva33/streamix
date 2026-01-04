defmodule Streamix.AI.Gemini do
  @moduledoc """
  Client for Google Gemini Embeddings API.

  Generates text embeddings using Google's Gemini embedding model
  for semantic search and content recommendations.

  ## Configuration

  Set the following environment variables:
  - `GEMINI_API_KEY` - Your Google AI Studio API key

  ## Model

  Uses `gemini-embedding-001` with 3072 dimensions.

  ## Task Types

  - `RETRIEVAL_DOCUMENT` - For indexing documents (content)
  - `RETRIEVAL_QUERY` - For search queries
  - `SEMANTIC_SIMILARITY` - For finding similar content
  """

  require Logger

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @model "gemini-embedding-001"
  @embedding_dimensions 3072

  @doc """
  Returns the embedding dimensions for Gemini model.
  """
  def embedding_dimensions, do: @embedding_dimensions

  @doc """
  Checks if Gemini is configured and enabled.
  """
  def enabled? do
    api_key() != nil and api_key() != ""
  end

  @doc """
  Generates embeddings for a single text (for search queries).

  Uses RETRIEVAL_QUERY task type optimized for search.

  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  def embed(text) when is_binary(text) do
    embed(text, task_type: "RETRIEVAL_QUERY")
  end

  @doc """
  Generates embeddings for a single text with options.

  ## Options
  - `:task_type` - RETRIEVAL_QUERY, RETRIEVAL_DOCUMENT, SEMANTIC_SIMILARITY

  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  def embed(text, opts) when is_binary(text) do
    if enabled?() do
      task_type = Keyword.get(opts, :task_type, "RETRIEVAL_QUERY")
      do_embed(text, task_type)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Generates embeddings for multiple texts using batch API.

  Uses RETRIEVAL_DOCUMENT task type by default (for indexing).
  Much more efficient than individual calls.

  Returns `{:ok, [[float]]}` or `{:error, reason}`.
  """
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    if enabled?() do
      task_type = Keyword.get(opts, :task_type, "RETRIEVAL_DOCUMENT")
      do_embed_batch(texts, task_type)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Generates embeddings for content (movie, series, etc).

  Combines title, description, and genres into a single text
  for embedding generation. Uses RETRIEVAL_DOCUMENT task type.
  """
  def embed_content(%{title: _title} = content) do
    text = build_content_text(content)
    embed(text, task_type: "RETRIEVAL_DOCUMENT")
  end

  @doc """
  Generates embeddings for multiple content items using batch API.

  Returns `{:ok, [{id, [float]}]}` where each tuple contains
  the content ID and its embedding vector.
  """
  def embed_contents(contents) when is_list(contents) do
    texts = Enum.map(contents, &build_content_text/1)

    case embed_batch(texts, task_type: "RETRIEVAL_DOCUMENT") do
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

  defp do_embed(text, task_type) do
    url = "#{@base_url}/models/#{@model}:embedContent?key=#{api_key()}"

    body =
      Jason.encode!(%{
        model: "models/#{@model}",
        content: %{
          parts: [%{text: text}]
        },
        taskType: task_type,
        outputDimensionality: @embedding_dimensions
      })

    headers = [{"Content-Type", "application/json"}]

    case Req.post(url, body: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embedding = body["embedding"]["values"]
        {:ok, embedding}

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.error("[Gemini] Quota exceeded (429): #{inspect(body)}")
        {:error, {:quota_exceeded, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Gemini] API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[Gemini] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp do_embed_batch(texts, task_type) do
    url = "#{@base_url}/models/#{@model}:batchEmbedContents?key=#{api_key()}"

    requests =
      Enum.map(texts, fn text ->
        %{
          model: "models/#{@model}",
          content: %{parts: [%{text: text}]},
          taskType: task_type,
          outputDimensionality: @embedding_dimensions
        }
      end)

    body = Jason.encode!(%{requests: requests})
    headers = [{"Content-Type", "application/json"}]

    case Req.post(url, body: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embeddings =
          body["embeddings"]
          |> Enum.map(& &1["values"])

        {:ok, embeddings}

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.error("[Gemini] Quota exceeded (429): #{inspect(body)}")
        {:error, {:quota_exceeded, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[Gemini] Batch API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[Gemini] Batch request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp build_content_text(%{title: title} = content) do
    parts = [title]

    parts =
      if Map.get(content, :year),
        do: parts ++ ["(#{content.year})"],
        else: parts

    parts =
      if Map.get(content, :genres) && content.genres != [],
        do: parts ++ ["Genres: #{Enum.join(content.genres, ", ")}"],
        else: parts

    parts =
      if Map.get(content, :description) && content.description != "",
        do: parts ++ [content.description],
        else: parts

    parts =
      if Map.get(content, :plot) && content.plot != "",
        do: parts ++ [content.plot],
        else: parts

    Enum.join(parts, " | ")
  end

  defp api_key do
    Application.get_env(:streamix, :gemini, [])[:api_key] ||
      System.get_env("GEMINI_API_KEY")
  end
end
