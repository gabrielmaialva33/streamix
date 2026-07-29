defmodule Streamix.Workers.IndexEmbeddingsWorker do
  @moduledoc """
  Background worker for indexing content embeddings.

  Generates vector embeddings for movies and series to enable
  semantic search and recommendations.

  ## Scheduling

  Runs daily at 5 AM UTC (after content syncs complete).

  ## Usage

  Can also be triggered manually:

      Oban.insert(IndexEmbeddingsWorker.new(%{collection: "movies"}))
      Oban.insert(IndexEmbeddingsWorker.new(%{collection: "series"}))
      Oban.insert(IndexEmbeddingsWorker.new(%{}))  # All collections
  """

  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(150)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    semantic_search = semantic_search_module()

    case semantic_search.setup() do
      :ok ->
        index(semantic_search, args)

      {:error, :not_available} ->
        Logger.info("[IndexEmbeddings] Semantic search not available, skipping")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to set up semantic search: #{inspect(reason)}")
        {:error, {:setup_failed, reason}}
    end
  end

  defp index(semantic_search, args) do
    collection = Map.get(args, "collection")
    provider_id = Map.get(args, "provider_id")

    case collection do
      "movies" ->
        index_movies(semantic_search, provider_id)

      "series" ->
        index_series(semantic_search, provider_id)

      _ ->
        case index_movies(semantic_search, provider_id) do
          :ok -> index_series(semantic_search, provider_id)
          {:error, _reason} = error -> error
        end
    end
  end

  defp index_movies(semantic_search, provider_id) do
    Logger.info("[IndexEmbeddings] Starting movies indexing...")

    case semantic_search.index_all_movies(provider_id) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} movies")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index movies: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp index_series(semantic_search, provider_id) do
    Logger.info("[IndexEmbeddings] Starting series indexing...")

    case semantic_search.index_all_series(provider_id) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} series")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index series: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp semantic_search_module do
    Application.get_env(:streamix, :semantic_search_module, Streamix.AI.SemanticSearch)
  end
end
