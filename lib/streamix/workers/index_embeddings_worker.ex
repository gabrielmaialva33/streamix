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

  alias Streamix.AI.SemanticSearch

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if SemanticSearch.available?() do
      collection = Map.get(args, "collection")
      provider_id = Map.get(args, "provider_id")

      case collection do
        "movies" ->
          index_movies(provider_id)

        "series" ->
          index_series(provider_id)

        _ ->
          # Index all
          index_movies(provider_id)
          index_series(provider_id)
      end
    else
      Logger.info("[IndexEmbeddings] Semantic search not available, skipping")
      :ok
    end
  end

  defp index_movies(provider_id) do
    Logger.info("[IndexEmbeddings] Starting movies indexing...")

    case SemanticSearch.index_all_movies(provider_id) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} movies")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index movies: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp index_series(provider_id) do
    Logger.info("[IndexEmbeddings] Starting series indexing...")

    case SemanticSearch.index_all_series(provider_id) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} series")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index series: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
