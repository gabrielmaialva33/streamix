defmodule Streamix.Queue.SyncPipeline do
  @moduledoc """
  Broadway pipeline for processing sync tasks from RabbitMQ.

  This pipeline consumes sync tasks and processes them with configurable
  concurrency, providing automatic retries and rate limit handling.

  ## Task Types

  ### GIndex
  - `gindex_full_sync` - Full sync of a GIndex provider
  - `gindex_movies` - Sync movies from a specific path
  - `gindex_series` - Sync series from a specific path
  - `gindex_animes` - Sync animes from a specific path

  ### IPTV (Xtream)
  - `iptv_categories` - Sync categories (live, vod, series)
  - `iptv_live` - Sync live channels
  - `iptv_movies` - Sync VOD movies
  - `iptv_series` - Sync series
  """

  use Broadway

  require Logger

  alias Broadway.Message
  alias Streamix.Queue.{Connection, SyncTask}

  @doc """
  Starts the Broadway pipeline.
  """
  def start_link(opts) do
    config = Application.get_env(:streamix, :rabbitmq, [])
    broadway_config = Keyword.get(config, :broadway, [])

    processor_concurrency = Keyword.get(broadway_config, :processor_concurrency, 5)

    queue = Keyword.get(opts, :queue, "streamix.sync.normal")

    Broadway.start_link(__MODULE__,
      name: broadway_name(queue),
      producer: [
        module: {
          BroadwayRabbitMQ.Producer,
          queue: queue,
          connection: Connection.connection_url(),
          qos: [prefetch_count: processor_concurrency],
          on_failure: :reject_and_requeue_once,
          metadata: [:routing_key, :headers]
        },
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: processor_concurrency,
          max_demand: 1
        ]
      ]
    )
  end

  # Callbacks

  @impl true
  def handle_message(_processor, %Message{data: data} = message, _context) do
    case SyncTask.execute(data) do
      {:ok, type, result} ->
        Logger.info(
          "[SyncPipeline] Task completed type=#{inspect(type)} result=#{inspect(result)}"
        )

        message

      {:error, type, reason, action} ->
        log_failure(type, reason, action)

        message
        |> configure_failure(action)
        |> Message.failed(reason)
    end
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("[SyncPipeline] Message failed: #{inspect(message.status)}")
    end)

    messages
  end

  defp configure_failure(message, :discard),
    do: Message.configure_ack(message, on_failure: :reject)

  defp configure_failure(message, :retry), do: message

  defp log_failure(type, reason, :discard) do
    Logger.warning(
      "[SyncPipeline] Discarding task type=#{inspect(type)} reason=#{inspect(reason)}"
    )
  end

  defp log_failure(type, reason, :retry) do
    Logger.error("[SyncPipeline] Task failed type=#{inspect(type)} reason=#{inspect(reason)}")
  end

  defp broadway_name("streamix.sync.high"), do: Streamix.Queue.SyncPipeline.High
  defp broadway_name("streamix.sync.normal"), do: Streamix.Queue.SyncPipeline.Normal
  defp broadway_name("streamix.sync.low"), do: Streamix.Queue.SyncPipeline.Low

  defp broadway_name(queue) do
    raise ArgumentError, "unsupported RabbitMQ sync queue: #{inspect(queue)}"
  end
end
