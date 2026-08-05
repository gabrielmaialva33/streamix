defmodule Streamix.Queue.Publisher do
  @moduledoc """
  Publisher for sync tasks to RabbitMQ.

  Provides functions to enqueue sync tasks with different priorities.
  Tasks are distributed across workers for parallel processing.
  """

  require Logger

  alias Streamix.Queue.{Connection, SyncTask}

  @exchange "streamix.sync"
  @priorities [:high, :normal, :low]
  @gindex_task_types %{
    movies: :gindex_movies,
    series: :gindex_series,
    animes: :gindex_animes
  }

  @doc """
  Publishes a sync task to the queue.

  ## Options

    * `:priority` - Task priority: `:high`, `:normal` (default), `:low`
    * `:message_priority` - RabbitMQ message priority (0-10, default: 5)

  ## Examples

      # Sync a specific folder with high priority
      Publisher.publish_sync_task(%{
        type: :gindex_movies,
        provider_id: 4,
        path: "/1:/Filmes/2024/"
      }, priority: :high)

      # Sync a series root with normal priority
      Publisher.publish_sync_task(%{
        type: :gindex_series,
        provider_id: 4,
        path: "/1:/Séries/"
      })
  """
  def publish_sync_task(task, opts \\ []) do
    with {:ok, type} <- fetch_task_type(task),
         {:ok, priority} <- validate_priority(Keyword.get(opts, :priority, :normal)),
         {:ok, message_priority} <-
           validate_message_priority(Keyword.get(opts, :message_priority, 5)),
         task_id = generate_task_id(),
         {:ok, payload} <- encode_payload(task, task_id) do
      publish(type, priority, message_priority, task_id, payload)
    end
  end

  @doc """
  Publishes multiple sync tasks in batch.
  """
  def publish_batch(tasks, opts \\ []) do
    results = Enum.map(tasks, &publish_sync_task(&1, opts))

    case summarize_results(results) do
      {:ok, summary} = result ->
        Logger.info("[Publisher] Batch published: #{summary.success} success, 0 failed")
        result

      {:error, {:batch_publish_failed, summary}} = error ->
        Logger.error(
          "[Publisher] Batch publish incomplete: #{summary.success} success, " <>
            "#{summary.failed} failed"
        )

        error
    end
  end

  @doc """
  Enqueues a GIndex provider sync, splitting into multiple tasks by category.
  """
  def enqueue_gindex_sync(provider_id, roots, opts \\ []) do
    with {:ok, tasks} <- build_gindex_tasks(provider_id, roots) do
      results = Enum.map(tasks, &publish_gindex_task(&1, opts))

      case summarize_results(results) do
        {:ok, %{success: count}} -> {:ok, count}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc false
  @spec build_gindex_tasks(pos_integer(), [map()]) ::
          {:ok, [map()]}
          | {:error, :empty_gindex_roots | {:invalid_gindex_root, term()}}
  def build_gindex_tasks(provider_id, []) when is_integer(provider_id) and provider_id > 0,
    do: {:error, :empty_gindex_roots}

  def build_gindex_tasks(provider_id, roots)
      when is_integer(provider_id) and provider_id > 0 and is_list(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, tasks} ->
      case build_gindex_task(provider_id, root) do
        {:ok, task} -> {:cont, {:ok, [task | tasks]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      {:error, _reason} = error -> error
    end
  end

  def build_gindex_tasks(_provider_id, roots), do: {:error, {:invalid_gindex_root, roots}}

  defp build_gindex_task(provider_id, %{kind: kind, path: path})
       when kind in [:movies, :series, :animes] and is_binary(path) do
    if String.trim(path) == "" do
      {:error, {:invalid_gindex_root, %{kind: kind, path: path}}}
    else
      {:ok,
       %{
         type: Map.fetch!(@gindex_task_types, kind),
         provider_id: provider_id,
         path: path
       }}
    end
  end

  defp build_gindex_task(_provider_id, root), do: {:error, {:invalid_gindex_root, root}}

  @doc """
  Enqueues folder-level tasks for parallel processing.

  This breaks down a large sync into smaller folder-level tasks
  that can be processed by multiple workers.
  """
  def enqueue_folder_tasks(provider_id, paths, type, opts \\ []) do
    with :ok <- validate_folder_task(provider_id, paths, type) do
      tasks =
        Enum.map(paths, fn path ->
          %{
            type: type,
            provider_id: provider_id,
            path: path
          }
        end)

      publish_batch(tasks, priority: Keyword.get(opts, :priority, :normal))
    end
  end

  # Private functions

  defp publish_gindex_task(task, opts) do
    priority = if task.type == :gindex_movies, do: :normal, else: :low
    publish_sync_task(task, Keyword.put(opts, :priority, priority))
  end

  defp fetch_task_type(%{type: type}), do: validate_task_type(type)
  defp fetch_task_type(%{"type" => type}), do: validate_task_type(type)
  defp fetch_task_type(_task), do: {:error, :missing_task_type}

  defp validate_task_type(type) do
    if SyncTask.supported_type?(type),
      do: {:ok, to_string(type)},
      else: {:error, {:unsupported_task_type, type}}
  end

  defp validate_priority(priority) when priority in @priorities, do: {:ok, priority}
  defp validate_priority(priority), do: {:error, {:invalid_priority, priority}}

  defp validate_message_priority(priority)
       when is_integer(priority) and priority in 0..10,
       do: {:ok, priority}

  defp validate_message_priority(priority),
    do: {:error, {:invalid_message_priority, priority}}

  defp validate_folder_task(provider_id, paths, type)
       when is_integer(provider_id) and provider_id > 0 and is_list(paths) and paths != [] do
    valid_type? =
      (is_atom(type) or is_binary(type)) and
        to_string(type) in ["gindex_movies", "gindex_series", "gindex_animes"]

    valid_paths? =
      Enum.all?(paths, &(is_binary(&1) and String.trim(&1) != ""))

    if valid_type? and valid_paths?, do: :ok, else: {:error, :invalid_folder_tasks}
  end

  defp validate_folder_task(_provider_id, _paths, _type),
    do: {:error, :invalid_folder_tasks}

  defp encode_payload(task, task_id) do
    task
    |> Map.put(:enqueued_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put(:id, task_id)
    |> Jason.encode()
    |> case do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :invalid_task_payload}
    end
  end

  defp publish(type, priority, message_priority, task_id, payload) do
    routing_key = "sync.#{priority}.#{type}"

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

  defp summarize_results(results) do
    successes = Enum.count(results, &match?({:ok, _}, &1))
    errors = for {:error, reason} <- results, do: reason
    summary = %{success: successes, failed: length(errors)}

    if errors == [] do
      {:ok, summary}
    else
      {:error, {:batch_publish_failed, Map.put(summary, :reasons, Enum.take(errors, 5))}}
    end
  end

  defp generate_task_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
