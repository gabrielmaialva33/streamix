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
  alias Streamix.Iptv.Gindex
  alias Streamix.Iptv.Sync.{Categories, Live, Movies, Series}
  alias Streamix.Queue.Connection

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
    case Jason.decode(data) do
      {:ok, task} ->
        Logger.info("[SyncPipeline] Processing task: #{task["type"]}")

        case process_task(task) do
          {:ok, result} ->
            Logger.info("[SyncPipeline] Task completed: #{task["type"]} - #{inspect(result)}")
            message

          {:error, reason} ->
            Logger.error("[SyncPipeline] Task failed: #{task["type"]} - #{inspect(reason)}")
            Message.failed(message, inspect(reason))
        end

      {:error, reason} ->
        Logger.error("[SyncPipeline] Failed to decode message: #{inspect(reason)}")
        Message.failed(message, "Invalid JSON: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("[SyncPipeline] Message failed: #{inspect(message.status)}")
    end)

    messages
  end

  # Task processors

  defp process_task(%{"type" => "gindex_full_sync", "provider_id" => provider_id}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    Gindex.Sync.sync_provider(provider)
  end

  defp process_task(%{"type" => "gindex_movies", "provider_id" => provider_id, "path" => path}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    base_url = provider.gindex_url

    Logger.info("[SyncPipeline] Syncing movies from: #{path}")

    # Use existing sync_category function
    case Gindex.Scraper.scrape_category(base_url, path) do
      {:ok, movies} when is_list(movies) ->
        Logger.info("[SyncPipeline] Scraped #{length(movies)} movies from #{path}")
        # Upsert movies to database
        Gindex.Sync.sync_movies_batch(provider, movies)

      {:error, reason} ->
        {:error, {:scrape_failed, reason}}
    end
  end

  defp process_task(%{"type" => "gindex_series", "provider_id" => provider_id, "path" => path}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    base_url = provider.gindex_url

    Logger.info("[SyncPipeline] Syncing series from: #{path}")

    case Gindex.Scraper.scrape_series_folder(base_url, path) do
      {:ok, series_list} when is_list(series_list) ->
        Logger.info("[SyncPipeline] Scraped #{length(series_list)} series from #{path}")
        Gindex.Sync.sync_series_batch(provider, series_list)

      {:error, reason} ->
        {:error, {:scrape_failed, reason}}
    end
  end

  defp process_task(%{"type" => "gindex_animes", "provider_id" => provider_id, "path" => path}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    base_url = provider.gindex_url

    Logger.info("[SyncPipeline] Syncing animes from: #{path}")

    case Gindex.Scraper.scrape_animes(base_url, path) do
      {:ok, animes} when is_list(animes) ->
        Logger.info("[SyncPipeline] Scraped #{length(animes)} animes from #{path}")
        Gindex.Sync.sync_animes_batch(provider, animes)

      {:error, reason} ->
        {:error, {:scrape_failed, reason}}
    end
  end

  # IPTV (Xtream) task processors

  defp process_task(%{"type" => "iptv_categories", "provider_id" => provider_id}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    Logger.info("[SyncPipeline] Syncing IPTV categories for provider #{provider_id}")

    case Categories.sync_categories(provider) do
      {:ok, count} ->
        Logger.info("[SyncPipeline] Synced #{count} categories")
        {:ok, %{categories: count}}

      {:error, reason} ->
        {:error, {:sync_failed, reason}}
    end
  end

  defp process_task(%{"type" => "iptv_live", "provider_id" => provider_id}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    Logger.info("[SyncPipeline] Syncing IPTV live channels for provider #{provider_id}")

    case Live.sync_live_channels(provider) do
      {:ok, count} ->
        Logger.info("[SyncPipeline] Synced #{count} live channels")
        {:ok, %{live_channels: count}}

      {:error, reason} ->
        {:error, {:sync_failed, reason}}
    end
  end

  defp process_task(%{"type" => "iptv_movies", "provider_id" => provider_id}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    Logger.info("[SyncPipeline] Syncing IPTV movies for provider #{provider_id}")

    case Movies.sync_movies(provider) do
      {:ok, count} ->
        Logger.info("[SyncPipeline] Synced #{count} movies")
        {:ok, %{movies: count}}

      {:error, reason} ->
        {:error, {:sync_failed, reason}}
    end
  end

  defp process_task(%{"type" => "iptv_series", "provider_id" => provider_id}) do
    provider = Streamix.Repo.get!(Streamix.Iptv.Provider, provider_id)
    Logger.info("[SyncPipeline] Syncing IPTV series for provider #{provider_id}")

    case Series.sync_series(provider) do
      {:ok, count} ->
        Logger.info("[SyncPipeline] Synced #{count} series")
        {:ok, %{series: count}}

      {:error, reason} ->
        {:error, {:sync_failed, reason}}
    end
  end

  defp process_task(%{"type" => type}) do
    Logger.warning("[SyncPipeline] Unknown task type: #{type}")
    {:error, :unknown_task_type}
  end

  defp process_task(_task) do
    {:error, :invalid_task}
  end

  defp broadway_name(queue) do
    # Create a unique atom name based on queue
    queue_suffix = queue |> String.replace(".", "_")
    :"Streamix.Queue.SyncPipeline.#{queue_suffix}"
  end
end
