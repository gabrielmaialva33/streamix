defmodule Streamix.Queue do
  @moduledoc """
  Queue system for distributed sync workers using RabbitMQ and Broadway.

  This module provides a facade for enqueueing sync tasks that are processed
  by distributed workers. The typed provider entrypoints fall back to Oban
  when RabbitMQ is disabled.

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
      Queue.enqueue_gindex_sync(provider)

      # Publish a RabbitMQ-only path task with high priority
      Queue.enqueue(
        :gindex_movies,
        %{provider_id: provider.id, path: "/1:/Filmes/"},
        priority: :high
      )
  """

  require Logger

  alias Streamix.Gindex
  alias Streamix.Queue.Publisher
  alias Streamix.Workers.{SyncGindexProviderWorker, SyncProviderWorker}

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
  Publishes a generic RabbitMQ sync task.

  Generic tasks have no safe one-to-one Oban fallback. When RabbitMQ is
  disabled this returns `{:error, :rabbitmq_disabled}`; use
  `enqueue_gindex_sync/1` or `enqueue_iptv_sync/1` when backend fallback is
  required.

  ## Options

    * `:priority` - Task priority: `:high`, `:normal`, `:low`
  """
  def enqueue(type, payload, opts \\ []) do
    task = payload |> Map.delete("type") |> Map.put(:type, type)
    enqueue_sync(task, opts)
  end

  @doc """
  Publishes a RabbitMQ sync task with the task map directly.

  Returns `{:error, :rabbitmq_disabled}` instead of silently mapping an
  unsupported generic task onto an unrelated Oban worker.

  ## Examples

      Queue.enqueue_sync(%{type: "gindex_full_sync", provider_id: 4}, priority: :high)
  """
  def enqueue_sync(task, opts \\ []) when is_map(task) do
    if enabled?() do
      Publisher.publish_sync_task(task, opts)
    else
      {:error, :rabbitmq_disabled}
    end
  end

  @doc """
  Enqueues an IPTV provider sync (live, vod, series).

  When RabbitMQ is enabled, splits the sync into parallel tasks.
  When disabled, falls back to direct execution via Oban.
  """
  def enqueue_iptv_sync(provider) do
    if enabled?() do
      enqueue_iptv_via_rabbitmq(provider)
    else
      enqueue_iptv_via_oban(provider)
    end
  end

  # Private functions

  defp enqueue_gindex_via_rabbitmq(provider) do
    roots = Gindex.sync_roots_for(provider)

    Logger.info("[Queue] Enqueueing GIndex sync for provider #{provider.id} via RabbitMQ")
    Publisher.enqueue_gindex_sync(provider.id, roots)
  end

  defp enqueue_gindex_via_oban(provider) do
    Logger.info("[Queue] Enqueueing GIndex sync for provider #{provider.id} via Oban")

    %{provider_id: provider.id}
    |> SyncGindexProviderWorker.new()
    |> Oban.insert()
  end

  defp enqueue_iptv_via_rabbitmq(provider) do
    Logger.info("[Queue] Enqueueing IPTV sync for provider #{provider.id} via RabbitMQ")

    # Create tasks for each sync type (run in parallel)
    tasks = [
      %{type: "iptv_categories", provider_id: provider.id},
      %{type: "iptv_live", provider_id: provider.id},
      %{type: "iptv_movies", provider_id: provider.id},
      %{type: "iptv_series", provider_id: provider.id}
    ]

    case Publisher.publish_batch(tasks, priority: :normal) do
      {:ok, %{success: count}} -> {:ok, count}
      {:error, _reason} = error -> error
    end
  end

  defp enqueue_iptv_via_oban(provider) do
    Logger.info("[Queue] Enqueueing IPTV sync for provider #{provider.id} via Oban")

    %{provider_id: provider.id}
    |> SyncProviderWorker.new()
    |> Oban.insert()
  end
end
