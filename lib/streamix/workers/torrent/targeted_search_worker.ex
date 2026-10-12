defmodule Streamix.Workers.Torrent.TargetedSearchWorker do
  @moduledoc """
  Runs `Streamix.Torrent.targeted_search/4` for one source over a list of
  wanted catalog movies.

  Args:

      %{
        "provider_id" => 1,
        "source_slug" => "gratistorrent",
        "wanted" => [%{"tmdb_id" => "1003469", "imdb_id" => "tt18559372",
                       "year" => 2022, "title" => "Combinação do Azevinho"}]
      }

  Enqueue through `Streamix.Torrent.enqueue_targeted_search/2`, which
  creates one job per searchable source. A job walks its list sequentially
  at the site's polite pace (≥1.5 s between requests) and checkpoints
  `next_index` in `meta` after every title, so a retry resumes where the
  previous attempt stopped.

  Halts are retried with a long backoff (15 min × attempt): a site that
  answered 429 three times in a row gets time to cool down. A layout change
  or a switched-off source is cancelled instead — retrying cannot fix a
  selector or a config flag.

  Only one job per `{provider_id, source_slug}` may be pending or running.
  """

  use Oban.Worker,
    queue: :torrent_sync,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:provider_id, :source_slug],
      states: :incomplete
    ]

  alias Streamix.Providers
  alias Streamix.Torrent

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(150)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 15 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{"provider_id" => provider_id, "source_slug" => source_slug, "wanted" => wanted},
        meta: meta
      }) do
    with {:provider, %{provider_type: :torrent} = provider} <-
           {:provider, Providers.get_provider(provider_id)},
         {:source, source} when not is_nil(source) <- {:source, Torrent.source_for(source_slug)},
         {:wanted, {:ok, wanted}} <- {:wanted, Torrent.normalize_wanted(wanted)} do
      opts = [
        start_index: checkpoint_index(meta, length(wanted)),
        on_progress: &persist_checkpoint(job_id, &1)
      ]

      provider
      |> Torrent.targeted_search(source, wanted, opts)
      |> finish(provider)
    else
      {:provider, nil} -> {:cancel, :provider_not_found}
      {:provider, _provider} -> {:cancel, :not_torrent_provider}
      {:source, nil} -> {:cancel, :unknown_source}
      {:wanted, {:error, reason}} -> {:cancel, reason}
    end
  end

  defp finish({:ok, report}, provider) do
    refresh_stats(provider, report)
    :ok
  end

  defp finish({:error, reason, report}, provider) do
    # Matches ingested before the halt are real; make them visible now.
    refresh_stats(provider, report)

    cond do
      reason in [:search_not_supported, :source_disabled] -> {:cancel, reason}
      Torrent.failure_state(reason) == "layout_changed" -> {:cancel, reason}
      true -> {:error, reason}
    end
  end

  defp refresh_stats(_provider, %{matched: 0}), do: :ok

  defp refresh_stats(provider, _report) do
    case Torrent.refresh_catalog_stats(provider.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Torrent TargetedSearch] stats refresh failed: #{inspect(reason)}")
    end
  end

  defp checkpoint_index(meta, total) when is_map(meta) do
    case Map.get(meta, "next_index") do
      index when is_integer(index) and index >= 0 and index <= total -> index
      _ -> 0
    end
  end

  defp checkpoint_index(_meta, _total), do: 0

  defp persist_checkpoint(nil, _report), do: :ok

  defp persist_checkpoint(job_id, report) do
    checkpoint = %{
      "next_index" => report.next_index,
      "searched" => report.searched,
      "matched" => report.matched,
      "torrents" => report.torrents
    }

    case Oban.update_job(job_id, fn job -> %{meta: Map.merge(job.meta, checkpoint)} end) do
      {:ok, _job} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
