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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    provider_id = args["provider_id"]
    series_details = parse_series_details_option(args["series_details"])

    case Iptv.get_provider(provider_id) do
      nil ->
        {:error, :provider_not_found}

      provider ->
        # Update status to syncing
        Iptv.update_provider(provider, %{sync_status: "syncing"})
        broadcast_sync_status(provider, "syncing")

        sync_opts = [series_details: series_details]

        case Iptv.sync_provider(provider, sync_opts) do
          {:ok, _result} ->
            # Reload provider to get updated counts
            updated_provider = Iptv.get_provider!(provider.id)

            # Update status to completed
            Iptv.update_provider(provider, %{sync_status: "completed"})

            broadcast_sync_status(provider, "completed", %{
              live_count: updated_provider.live_count,
              movies_count: updated_provider.movies_count,
              series_count: updated_provider.series_count
            })

            :ok

          {:error, reason} ->
            # Update status to failed
            Iptv.update_provider(provider, %{sync_status: "failed"})
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
