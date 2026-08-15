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
      states: :incomplete
    ]

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(150)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    semantic_search = semantic_search_module()

    case semantic_search.setup() do
      :ok ->
        index(semantic_search, job)

      {:error, :not_available} ->
        Logger.info("[IndexEmbeddings] Semantic search not available, skipping")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to set up semantic search: #{inspect(reason)}")
        {:error, {:setup_failed, reason}}
    end
  end

  defp index(semantic_search, %Oban.Job{args: args, meta: meta} = job) do
    collection = Map.get(args, "collection")
    provider_id = Map.get(args, "provider_id")

    case collection do
      "movies" ->
        index_movies(semantic_search, provider_id, job)

      "series" ->
        index_series(semantic_search, provider_id, job)

      "animes" ->
        index_animes(semantic_search, provider_id, job)

      _ ->
        index_all(semantic_search, provider_id, job, checkpoint_collection(meta))
    end
  end

  # Resuming picks up at the collection the checkpoint stopped on and carries
  # on through the ones that follow it.
  defp index_all(semantic_search, provider_id, job, "animes") do
    index_animes(semantic_search, provider_id, job)
  end

  defp index_all(semantic_search, provider_id, job, "series") do
    with :ok <- index_series(semantic_search, provider_id, job) do
      continue_with(semantic_search, provider_id, job, "animes", &index_animes/3)
    end
  end

  defp index_all(semantic_search, provider_id, job, _checkpoint_collection) do
    with :ok <- index_movies(semantic_search, provider_id, job),
         :ok <- persist_checkpoint(job.id, "series", 0),
         :ok <-
           index_series(semantic_search, provider_id, %{
             job
             | meta: collection_checkpoint("series")
           }) do
      continue_with(semantic_search, provider_id, job, "animes", &index_animes/3)
    end
  end

  defp continue_with(semantic_search, provider_id, job, collection, indexer) do
    with :ok <- persist_checkpoint(job.id, collection, 0) do
      indexer.(semantic_search, provider_id, %{job | meta: collection_checkpoint(collection)})
    end
  end

  defp index_movies(semantic_search, provider_id, job) do
    after_id = checkpoint_after_id(job.meta, "movies")
    Logger.info("[IndexEmbeddings] Starting movies indexing after id #{after_id}...")

    case semantic_search.index_all_movies(
           provider_id,
           checkpoint_opts(job.id, "movies", after_id)
         ) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} movies this attempt")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index movies: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp index_series(semantic_search, provider_id, job) do
    after_id = checkpoint_after_id(job.meta, "series")
    Logger.info("[IndexEmbeddings] Starting series indexing after id #{after_id}...")

    case semantic_search.index_all_series(
           provider_id,
           checkpoint_opts(job.id, "series", after_id)
         ) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} series this attempt")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index series: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp index_animes(semantic_search, provider_id, job) do
    after_id = checkpoint_after_id(job.meta, "animes")
    Logger.info("[IndexEmbeddings] Starting animes indexing after id #{after_id}...")

    case semantic_search.index_all_animes(
           provider_id,
           checkpoint_opts(job.id, "animes", after_id)
         ) do
      {:ok, count} ->
        Logger.info("[IndexEmbeddings] Indexed #{count} animes this attempt")
        :ok

      {:error, reason} ->
        Logger.error("[IndexEmbeddings] Failed to index animes: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp checkpoint_opts(job_id, collection, after_id) do
    [
      after_id: after_id,
      on_batch: fn last_id, _indexed_total ->
        persist_checkpoint(job_id, collection, last_id)
      end
    ]
  end

  defp checkpoint_collection(meta) when is_map(meta) do
    Map.get(meta, "checkpoint_collection")
  end

  defp checkpoint_collection(_meta), do: nil

  defp checkpoint_after_id(meta, collection) when is_map(meta) do
    case {checkpoint_collection(meta), Map.get(meta, "checkpoint_after_id")} do
      {^collection, after_id} when is_integer(after_id) and after_id >= 0 -> after_id
      _ -> 0
    end
  end

  defp checkpoint_after_id(_meta, _collection), do: 0

  defp persist_checkpoint(nil, _collection, _after_id), do: :ok

  defp persist_checkpoint(job_id, collection, after_id) do
    checkpoint = %{
      "checkpoint_collection" => collection,
      "checkpoint_after_id" => after_id
    }

    case Oban.update_job(job_id, fn job ->
           %{meta: Map.merge(job.meta, checkpoint)}
         end) do
      {:ok, _job} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp collection_checkpoint(collection) do
    %{
      "checkpoint_collection" => collection,
      "checkpoint_after_id" => 0
    }
  end

  defp semantic_search_module do
    Application.get_env(:streamix, :semantic_search_module, Streamix.AI.SemanticSearch)
  end
end
