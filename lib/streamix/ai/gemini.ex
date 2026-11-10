defmodule Streamix.AI.Gemini do
  @behaviour Streamix.AI.EmbeddingProvider

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

  alias Streamix.AI.ContentText
  alias Streamix.SafeLog

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
    text = ContentText.build(content)
    embed(text, task_type: "RETRIEVAL_DOCUMENT")
  end

  @doc """
  Generates embeddings for multiple content items using batch API.

  Returns `{:ok, [{id, [float]}]}` where each tuple contains
  the content ID and its embedding vector.
  """
  def embed_contents(contents) when is_list(contents) do
    texts = Enum.map(contents, &ContentText.build/1)

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

  @doc """
  Asks a Gemini text model for JSON matching `schema` (an OpenAPI-subset
  `responseSchema`, where string enums constrain the answer).

  The key travels in the `x-goog-api-key` header, never in the URL. Returns
  the decoded JSON and the token usage, or `{:error, :quota_exhausted}` (the
  daily quota is spent), `{:error, :rate_limited}`, `{:error, :unauthorized}`,
  `{:error, :not_configured}` or another error.

  ## Options

    * `:model` (required) — e.g. `"gemini-3.8-flash"`
    * `:temperature` — default 0.2
    * `:thinking` — a `thinkingConfig` map passed through as is
    * `:timeout` — receive timeout in ms, default 120_000
    * `:max_retries` — retries of a 408/429/5xx answer, default 4
  """
  @spec generate_json(String.t(), String.t(), map(), keyword()) ::
          {:ok, term(), map()} | {:error, term()}
  def generate_json(system, prompt, schema, opts)
      when is_binary(system) and is_binary(prompt) and is_map(schema) do
    model = Keyword.fetch!(opts, :model)

    generation_config =
      %{
        responseMimeType: "application/json",
        responseSchema: schema,
        temperature: Keyword.get(opts, :temperature, 0.2)
      }
      |> maybe_put(:thinkingConfig, Keyword.get(opts, :thinking))

    body = %{
      systemInstruction: %{parts: [%{text: system}]},
      contents: [%{role: "user", parts: [%{text: prompt}]}],
      generationConfig: generation_config
    }

    if enabled?() do
      "#{@base_url}/models/#{model}:generateContent"
      |> Req.post(
        json: body,
        headers: [{"x-goog-api-key", api_key()}],
        receive_timeout: Keyword.get(opts, :timeout, 120_000),
        # 503 ("high demand") and per-minute 429s are routine on shared
        # Gemini capacity and worth a short wait. A spent daily quota is not:
        # its Retry-After can be hours, so it is never retried here.
        # The retry decision runs before Req decodes the body, so ask for an
        # uncompressed answer the quota check can read.
        compressed: false,
        retry: &retry_generate?/2,
        retry_delay: &generate_backoff/1,
        max_retries: Keyword.get(opts, :max_retries, 4)
      )
      |> handle_generate()
    else
      {:error, :not_configured}
    end
  end

  defp handle_generate({:ok, %Req.Response{status: 200, body: body}}) do
    with %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} <- body,
         text when is_binary(text) <- Enum.map_join(parts, &(&1["text"] || "")),
         {:ok, json} <- Jason.decode(text) do
      {:ok, json, Map.get(body, "usageMetadata", %{})}
    else
      %{"candidates" => [%{"finishReason" => reason} | _]} -> {:error, {:no_content, reason}}
      %{"promptFeedback" => %{"blockReason" => reason}} -> {:error, {:blocked, reason}}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      _other -> {:error, :unexpected_response}
    end
  end

  defp handle_generate({:ok, %Req.Response{status: 429} = response}) do
    if daily_quota?(response), do: {:error, :quota_exhausted}, else: {:error, :rate_limited}
  end

  defp handle_generate({:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp handle_generate({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("[Gemini] generateContent failed",
      reason: SafeLog.redact_inspect({status, body})
    )

    {:error, {:api_error, status}}
  end

  defp handle_generate({:error, reason}), do: {:error, {:request_failed, reason}}

  @doc false
  def retry_generate?(_request, %Req.Response{status: 429} = response),
    do: not daily_quota?(response)

  def retry_generate?(_request, %Req.Response{status: status}),
    do: status in [408, 500, 502, 503, 504]

  def retry_generate?(_request, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  def retry_generate?(_request, _other), do: false

  # 1, 2, 4, 8 s, capped at 16 s.
  defp generate_backoff(attempt), do: min(1_000 * Integer.pow(2, attempt), 16_000)

  defp daily_quota?(%Req.Response{body: %{"error" => %{} = error}}) do
    error
    |> Map.get("details")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"violations" => violations} -> List.wrap(violations)
      _detail -> []
    end)
    |> Enum.any?(&(is_map(&1) and String.contains?(to_string(&1["quotaId"]), "PerDay")))
  end

  defp daily_quota?(%Req.Response{body: body} = response) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> daily_quota?(%{response | body: decoded})
      _other -> false
    end
  end

  defp daily_quota?(_response), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
        Logger.error("[Gemini] Request failed", reason: SafeLog.redact_inspect(reason))
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
        Logger.error("[Gemini] Batch request failed", reason: SafeLog.redact_inspect(reason))
        {:error, {:request_failed, reason}}
    end
  end

  defp api_key do
    Application.get_env(:streamix, :gemini, [])[:api_key] ||
      System.get_env("GEMINI_API_KEY")
  end
end
