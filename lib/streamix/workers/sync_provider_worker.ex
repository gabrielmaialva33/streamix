defmodule Streamix.Workers.SyncProviderWorker do
  @moduledoc """
  Background worker for syncing IPTV provider content.
  Runs asynchronously to avoid blocking user requests.

  ## Options

  The job args can include:

    * `series_details` - How to handle series details:
      - `"skip"` (default) - Don't sync series details
      - `"enqueue"` - Enqueue background jobs to sync in batches (recommended)
      - `"immediate"` - Sync all immediately (slow, use for small providers)

  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 300, keys: [:provider_id]]

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider
  alias Streamix.Workers.SyncGindexProviderWorker
  alias Streamix.Workers.SyncTorrentProviderWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    iptv = iptv_module()
    provider_id = args["provider_id"]
    series_details = parse_series_details_option(args["series_details"])

    case iptv.get_provider(provider_id) do
      nil ->
        {:error, :provider_not_found}

      %{provider_type: :gindex} = provider ->
        # Defensive re-route: GIndex must always go through the dispatcher
        # (`SyncGindexProviderWorker`). Stale cron jobs, legacy enqueues
        # or manual `Oban.insert` calls landing here would otherwise run
        # `Gindex.Sync.sync_provider/1`, the monolithic single-shot path
        # that times out on catalogs with 10k+ titles.
        Logger.info(
          "[SyncProviderWorker] redispatching gindex provider #{provider.id} to GIndex dispatcher"
        )

        %{"provider_id" => provider.id}
        |> SyncGindexProviderWorker.new()
        |> Oban.insert()

        :ok

      %{provider_type: :torrent} = provider ->
        # Same defensive shape as the GIndex branch: torrent providers
        # are credential-less aggregators and `XtreamClient.build_url/5`
        # FunctionClauseErrors on their nil username/password. Route
        # them to the dedicated torrent worker. Production today still
        # ships a legacy "all non-gindex" enqueue in
        # `SyncAllProvidersWorker`, so this guard prevents the crash
        # even when an old cron job slips through.
        Logger.info(
          "[SyncProviderWorker] redispatching torrent provider #{provider.id} to Torrent worker"
        )

        %{"provider_id" => provider.id}
        |> SyncTorrentProviderWorker.new()
        |> Oban.insert()

        :ok

      provider ->
        run_xtream_sync(iptv, provider, series_details)
    end
  end

  defp run_xtream_sync(iptv, provider, series_details) do
    iptv.update_provider(provider, %{sync_status: "syncing"})
    broadcast_sync_status(provider, "syncing")

    case iptv.sync_provider(provider, series_details: series_details) do
      {:ok, _result} -> finish_success(iptv, provider)
      {:error, reason} -> finish_failure(iptv, provider, reason)
    end
  end

  # Confirm the status update BEFORE broadcasting. Broadcasting a
  # "completed" event when the DB still says "syncing" leaves the UI
  # permanently out of sync with the provider row.
  defp finish_success(iptv, provider) do
    updated_provider = iptv.get_provider!(provider.id)

    case iptv.update_provider(provider, %{sync_status: "completed"}) do
      {:ok, _} ->
        broadcast_sync_status(provider, "completed", %{
          live_channels_count: updated_provider.live_channels_count,
          movies_count: updated_provider.movies_count,
          series_count: updated_provider.series_count
        })

        :ok

      {:error, changeset} ->
        Logger.error(
          "[SyncProviderWorker] provider #{provider.id} sync succeeded " <>
            "but status update failed: #{inspect(changeset.errors)}"
        )

        {:error, {:status_update_failed, changeset}}
    end
  end

  # Same ordering as the success branch: broadcast only after the status
  # row reflects the outcome.
  defp finish_failure(iptv, provider, reason) do
    case iptv.update_provider(provider, %{sync_status: "failed"}) do
      {:ok, _} ->
        broadcast_sync_status(provider, "failed", %{error: inspect(reason)})

      {:error, changeset} ->
        Logger.error(
          "[SyncProviderWorker] provider #{provider.id} failed AND status " <>
            "update failed: #{inspect(changeset.errors)}"
        )
    end

    {:error, reason}
  end

  defp parse_series_details_option(nil), do: :skip
  defp parse_series_details_option("skip"), do: :skip
  defp parse_series_details_option("enqueue"), do: :enqueue
  defp parse_series_details_option("immediate"), do: :immediate
  defp parse_series_details_option(_), do: :skip

  @doc """
  Enqueues a sync job for the given provider.

  ## Options

    * `:series_details` - `:skip`, `:enqueue`, or `:immediate` (default: `:skip`)

  """
  def enqueue(provider_or_id, opts \\ [])

  def enqueue(%Provider{} = provider, opts) do
    series_details = Keyword.get(opts, :series_details, :skip)
    job_opts = job_opts(opts)

    %{provider_id: provider.id, series_details: to_string(series_details)}
    |> new(job_opts)
    |> Oban.insert()
  end

  def enqueue(provider_id, opts) when is_integer(provider_id) or is_binary(provider_id) do
    series_details = Keyword.get(opts, :series_details, :skip)
    job_opts = job_opts(opts)

    %{provider_id: provider_id, series_details: to_string(series_details)}
    |> new(job_opts)
    |> Oban.insert()
  end

  # Pass-through only what Oban's `new/2` understands. Anything else stays
  # behind in `opts` and is consumed by `perform/1` via args.
  defp job_opts(opts) do
    opts
    |> Keyword.take([:schedule_in, :scheduled_at, :priority, :tags, :replace])
  end

  defp iptv_module do
    Application.get_env(:streamix, :sync_provider_worker_iptv_module, Iptv)
  end

  defp broadcast_sync_status(provider, status, extra \\ %{}) do
    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "provider:#{provider.id}",
      {:sync_status, Map.merge(%{status: status, provider_id: provider.id}, extra)}
    )

    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "user:#{provider.user_id}:providers",
      {:sync_status, Map.merge(%{status: status, provider_id: provider.id}, extra)}
    )
  end
end
