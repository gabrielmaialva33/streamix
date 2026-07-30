defmodule Streamix.Workers.EnsureAiCollectionsWorker do
  @moduledoc """
  Ensures the collections required by semantic search and recommendations exist.

  The job runs once after each Oban boot. Collection creation is idempotent and
  failures retry in the background, so an optional Qdrant outage never blocks
  the Phoenix application from starting.
  """

  use Oban.Worker,
    queue: :ai,
    max_attempts: 10,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: :incomplete
    ]

  require Logger

  alias Streamix.AI

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(3)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    ensure_collections(ai_module())
  end

  defp ensure_collections(ai) do
    case ai.ensure_vector_collections() do
      :ok ->
        Logger.info("[EnsureAiCollections] Required Qdrant collections are ready")
        :ok

      {:ok, :disabled} ->
        Logger.debug("[EnsureAiCollections] AI vector search is disabled, skipping bootstrap")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ai_module do
    Application.get_env(:streamix, :ensure_ai_collections_ai_module, AI)
  end
end
