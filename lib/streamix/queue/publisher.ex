defmodule Streamix.Queue.Publisher do
  @moduledoc """
  Publisher for sync tasks to RabbitMQ.

  Provides functions to enqueue sync tasks with different priorities.
  Tasks are distributed across workers for parallel processing.
  """

  require Logger

  alias Streamix.Queue.Connection

  @exchange "streamix.sync"

  @doc """
  Publishes a sync task to the queue.

  ## Options

    * `:priority` - Task priority: `:high`, `:normal` (default), `:low`
    * `:message_priority` - RabbitMQ message priority (0-10, default: 5)

  ## Examples

      # Sync a specific folder with high priority
      Publisher.publish_sync_task(%{
        type: :gindex_folder,
        provider_id: 4,
        path: "/1:/Filmes/2024/"
      }, priority: :high)

      # Sync all movies with normal priority
      Publisher.publish_sync_task(%{
        type: :gindex_movies,
        provider_id: 4
      })
  """
  def publish_sync_task(task, opts \\ []) do
    priority = Keyword.get(opts, :priority, :normal)
    message_priority = Keyword.get(opts, :message_priority, 5)

    routing_key = "sync.#{priority}.#{task.type}"
    task_id = generate_task_id()

    payload =
      task
      |> Map.put(:enqueued_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put(:id, task_id)
      |> Jason.encode!()

    publish_options = [
      persistent: true,
      priority: message_priority,
      content_type: "application/json",
      timestamp: :os.system_time(:second)
    ]

    case Connection.get_channel() do
      nil ->
        Logger.error("[Publisher] No RabbitMQ channel available")
        {:error, :no_connection}

      channel ->
        case AMQP.Basic.publish(channel, @exchange, routing_key, payload, publish_options) do
          :ok ->
            Logger.debug("[Publisher] Published task: #{routing_key}")
            {:ok, task_id}

          error ->
            Logger.error("[Publisher] Failed to publish: #{inspect(error)}")
            error
        end
    end
  end

  @doc """
  Publishes multiple sync tasks in batch.
  """
  def publish_batch(tasks, opts \\ []) do
    results = Enum.map(tasks, &publish_sync_task(&1, opts))

    successes = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("[Publisher] Batch published: #{successes} success, #{failures} failed")
    {:ok, %{success: successes, failed: failures}}
  end

  @doc """
  Enqueues a GIndex provider sync, splitting into multiple tasks by category.
  """
  def enqueue_gindex_sync(provider_id, paths, opts \\ []) do
    # Create tasks for each path
    tasks =
      Enum.flat_map(paths, fn {type, path_or_paths} ->
        case path_or_paths do
          paths when is_list(paths) ->
            Enum.map(paths, fn path ->
              %{
                type: :"gindex_#{type}",
                provider_id: provider_id,
                path: path
              }
            end)

          path when is_binary(path) ->
            [
              %{
                type: :"gindex_#{type}",
                provider_id: provider_id,
                path: path
              }
            ]
        end
      end)

    # Movies get normal priority, series/animes get low (they take longer)
    grouped =
      Enum.group_by(tasks, fn task ->
        if task.type == :gindex_movies, do: :normal, else: :low
      end)

    # Publish each group with appropriate priority
    Enum.each(grouped, fn {priority, group_tasks} ->
      publish_batch(group_tasks, Keyword.merge(opts, priority: priority))
    end)

    {:ok, length(tasks)}
  end

  @doc """
  Enqueues folder-level tasks for parallel processing.

  This breaks down a large sync into smaller folder-level tasks
  that can be processed by multiple workers.
  """
  def enqueue_folder_tasks(provider_id, folders, type, opts \\ []) do
    priority = Keyword.get(opts, :priority, :normal)

    tasks =
      Enum.map(folders, fn folder ->
        %{
          type: type,
          provider_id: provider_id,
          folder: folder
        }
      end)

    publish_batch(tasks, priority: priority)
  end

  # Private functions

  defp generate_task_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
