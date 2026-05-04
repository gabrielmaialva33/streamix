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

      provider ->
        # Update status to syncing
        iptv.update_provider(provider, %{sync_status: "syncing"})
        broadcast_sync_status(provider, "syncing")

        sync_opts = [series_details: series_details]

        case iptv.sync_provider(provider, sync_opts) do
          {:ok, _result} ->
            # Reload provider to get updated counts
            updated_provider = iptv.get_provider!(provider.id)

            # Update status to completed
            iptv.update_provider(provider, %{sync_status: "completed"})

            broadcast_sync_status(provider, "completed", %{
              live_channels_count: updated_provider.live_channels_count,
              movies_count: updated_provider.movies_count,
              series_count: updated_provider.series_count
            })

            :ok

          {:error, reason} ->
            # Update status to failed
            iptv.update_provider(provider, %{sync_status: "failed"})
            broadcast_sync_status(provider, "failed", %{error: inspect(reason)})
            {:error, reason}
        end
    end
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

    %{provider_id: provider.id, series_details: to_string(series_details)}
    |> new()
    |> Oban.insert()
  end

  def enqueue(provider_id, opts) when is_integer(provider_id) or is_binary(provider_id) do
    series_details = Keyword.get(opts, :series_details, :skip)

    %{provider_id: provider_id, series_details: to_string(series_details)}
    |> new()
    |> Oban.insert()
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
