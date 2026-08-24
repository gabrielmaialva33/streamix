defmodule Streamix.Workers.Torrent.SyncSourceWorker do
  @moduledoc """
  Oban worker that runs `Streamix.Torrent.Sync.sync_source/2`
  for a single `{provider_id, source_slug}` pair.

  Queue: `:torrent_sync`. Triggered by
  `Streamix.Workers.SyncTorrentProviderWorker`, one job per enabled
  source so a single misbehaving source can't sabotage the whole
  catalog.
  """

  use Oban.Worker, queue: :torrent_sync, max_attempts: 3

  alias Streamix.Providers
  alias Streamix.Torrent

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(150)

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{"provider_id" => provider_id, "source_slug" => source_slug} = args,
        meta: meta
      }) do
    with %{provider_type: :torrent} = provider <- Providers.get_provider(provider_id),
         module when is_atom(module) and not is_nil(module) <- Torrent.source_for(source_slug) do
      workflow_id = Map.get(args, "workflow_id")
      start_page = checkpoint_page(meta)
      base_movies = checkpoint_count(meta, "movies_processed")
      base_torrents = checkpoint_count(meta, "torrents_processed")

      on_page = fn progress ->
        persist_checkpoint(job_id, progress, base_movies, base_torrents)
      end

      case Torrent.sync_source(provider, module, start_page: start_page, on_page: on_page) do
        {:ok, stats} ->
          complete_sync(provider, workflow_id, provider_id, source_slug, stats)

        {:error, reason} ->
          Logger.error(
            "[Torrent SyncSource] provider=#{provider_id} slug=#{source_slug} failed: " <>
              inspect(reason)
          )

          {:error, reason}
      end
    else
      nil ->
        case Torrent.source_for(source_slug) do
          nil -> {:error, :unknown_source}
          _ -> {:error, :provider_not_found}
        end

      %{id: _} ->
        {:error, :not_torrent_provider}
    end
  end

  defp complete_sync(provider, workflow_id, provider_id, source_slug, stats) do
    # Coordinated fan-out runs are finalized only after every sibling
    # settles. Legacy/manual jobs without a workflow still finalize
    # themselves for backwards compatibility.
    maybe_finalize_provider(provider, workflow_id)

    Logger.info(
      "[Torrent SyncSource] provider=#{provider_id} slug=#{source_slug} ok " <>
        "movies=#{stats.movies} torrents=#{stats.torrents}"
    )

    :ok
  end

  defp maybe_finalize_provider(provider, nil), do: Torrent.refresh_provider_counts(provider)
  defp maybe_finalize_provider(_provider, _workflow_id), do: :ok

  defp checkpoint_page(meta) when is_map(meta) do
    case Map.get(meta, "next_page") do
      page when is_integer(page) and page > 0 -> page
      _ -> 1
    end
  end

  defp checkpoint_page(_meta), do: 1

  defp checkpoint_count(meta, key) when is_map(meta) do
    case Map.get(meta, key) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  defp checkpoint_count(_meta, _key), do: 0

  defp persist_checkpoint(nil, _progress, _base_movies, _base_torrents), do: :ok

  defp persist_checkpoint(job_id, progress, base_movies, base_torrents) do
    checkpoint = %{
      "last_page" => progress.page,
      "next_page" => progress.next_page,
      "movies_processed" => base_movies + progress.movies,
      "torrents_processed" => base_torrents + progress.torrents
    }

    case Oban.update_job(job_id, fn job ->
           %{meta: Map.merge(job.meta, checkpoint)}
         end) do
      {:ok, _job} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
