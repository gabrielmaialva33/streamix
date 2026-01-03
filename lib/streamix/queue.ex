defmodule Streamix.Queue do
  @moduledoc """
  Queue system for distributed sync workers using RabbitMQ and Broadway.

  This module provides a facade for enqueueing sync tasks that are processed
  by distributed workers. When RabbitMQ is not enabled, tasks fall back to
  direct execution (Oban).

  ## Architecture

  ```
  ┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
  │   Queue.enqueue │────▶│   RabbitMQ   │────▶│    Broadway     │
  │                 │     │   Exchange   │     │   Pipelines     │
  └─────────────────┘     └──────────────┘     └─────────────────┘
                                │                      │
                      ┌─────────┼─────────┐           │
                      ▼         ▼         ▼           │
                  [high]    [normal]   [low]          │
                      │         │         │           │
                      └─────────┴─────────┘           │
                                │                     ▼
                      ┌─────────────────────────────────┐
                      │  Workers (concurrency: 5)       │
                      │  - Scrape folders in parallel   │
                      │  - Auto-retry on rate limits    │
                      │  - Batch upserts to DB          │
                      └─────────────────────────────────┘
  ```

  ## Configuration

  Set `RABBITMQ_ENABLED=true` and configure RabbitMQ connection in runtime.exs.

  ## Usage

      # Enqueue a GIndex sync
      Queue.enqueue_gindex_sync(provider_id)

      # Enqueue with high priority
      Queue.enqueue(:sync_folder, %{path: "/1:/Filmes/"}, priority: :high)
  """

  require Logger

  alias Streamix.Queue.Publisher

  @doc """
  Checks if the queue system is enabled.
  """
  def enabled? do
    config = Application.get_env(:streamix, :rabbitmq, [])
    Keyword.get(config, :enabled, false)
  end

  @doc """
  Enqueues a GIndex provider sync.

  When RabbitMQ is enabled, this splits the sync into multiple tasks
  that are processed in parallel by workers.

  When disabled, falls back to direct execution via Oban.
  """
  def enqueue_gindex_sync(provider) do
    if enabled?() do
      enqueue_gindex_via_rabbitmq(provider)
    else
      enqueue_gindex_via_oban(provider)
    end
  end

  @doc """
  Enqueues a generic sync task.

  ## Options

    * `:priority` - Task priority: `:high`, `:normal`, `:low`
  """
  def enqueue(type, payload, opts \\ []) do
    if enabled?() do
      task = Map.put(payload, :type, type)
      Publisher.publish_sync_task(task, opts)
    else
      # Fall back to Oban
      Logger.debug("[Queue] RabbitMQ disabled, using Oban for #{type}")

      %{type: type, payload: payload}
      |> Streamix.Workers.SyncGindexProviderWorker.new()
      |> Oban.insert()
    end
  end

  # Private functions

  defp enqueue_gindex_via_rabbitmq(provider) do
    drives = provider.gindex_drives || %{}

    paths = %{
      movies: Map.get(drives, "movies_path"),
      series: Map.get(drives, "series_paths", []),
      animes: Map.get(drives, "animes_path")
    }

    # Filter out nil paths
    paths =
      paths
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
      |> Map.new()

    Logger.info("[Queue] Enqueueing GIndex sync for provider #{provider.id} via RabbitMQ")
    Publisher.enqueue_gindex_sync(provider.id, paths)
  end

  defp enqueue_gindex_via_oban(provider) do
    Logger.info("[Queue] Enqueueing GIndex sync for provider #{provider.id} via Oban")

    %{provider_id: provider.id}
    |> Streamix.Workers.SyncGindexProviderWorker.new()
    |> Oban.insert()
  end
end
