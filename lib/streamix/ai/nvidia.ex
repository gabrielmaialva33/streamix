defmodule Streamix.AI.Nvidia do
  @moduledoc """
  Client for NVIDIA NIM Embeddings API.

  Generates text embeddings using NVIDIA's models for semantic search
  and content recommendations.

  ## Configuration

  Set the following environment variables:
  - `NVIDIA_API_KEY` - Your NVIDIA NIM API key
  - `NVIDIA_EMBEDDING_MODEL` - Model to use (default: nv-embedqa-e5-v5)

  ## Rate Limits

  NVIDIA NIM has a rate limit of 40 requests per minute.
  Use batch processing to maximize throughput.
  """

  require Logger

  @base_url "https://ai.api.nvidia.com/v1/retrieval/nvidia"
  @default_model "nv-embedqa-e5-v5"
  @embedding_dimensions 1024

  @doc """
  Returns the embedding dimensions for the current model.
  """
  def embedding_dimensions, do: @embedding_dimensions

  @doc """
  Checks if NVIDIA NIM is configured and enabled.
  """
  def enabled? do
    api_key() != nil and api_key() != ""
  end

  @doc """
  Generates embeddings for a single text.

  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates embeddings for multiple texts in a single request.

  This is more efficient than calling `embed/1` multiple times
  due to rate limits (40 rpm).

  Returns `{:ok, [[float]]}` or `{:error, reason}`.
  """
  def embed_batch(texts) when is_list(texts) do
    if enabled?() do
      do_embed_batch(texts)
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
    text = build_content_text(content)
    embed(text)
  end

  @doc """
  Generates embeddings for multiple content items.

  Returns `{:ok, [{id, [float]}]}` where each tuple contains
  the content ID and its embedding vector.
  """
  def embed_contents(contents) when is_list(contents) do
    texts = Enum.map(contents, &build_content_text/1)

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

  defp do_embed_batch(texts) do
    url = "#{@base_url}/embeddings"

    body =
      Jason.encode!(%{
        input: texts,
        model: model(),
        input_type: "passage",
        encoding_format: "float",
        truncate: "END"
      })

    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    case Req.post(url, body: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embeddings =
          body["data"]
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, %Req.Response{status: 429}} ->
        Logger.warning("[NVIDIA] Rate limited, retrying in 2s")
        Process.sleep(2000)
        do_embed_batch(texts)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[NVIDIA] API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[NVIDIA] Request failed: #{inspect(reason)}")
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
    Application.get_env(:streamix, :nvidia, [])[:api_key] ||
      System.get_env("NVIDIA_API_KEY")
  end

  defp model do
    Application.get_env(:streamix, :nvidia, [])[:embedding_model] ||
      System.get_env("NVIDIA_EMBEDDING_MODEL") ||
      @default_model
  end
end
