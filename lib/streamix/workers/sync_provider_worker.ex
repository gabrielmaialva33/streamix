defmodule Streamix.Workers.SyncProviderWorker do
  @moduledoc """
  Background worker for syncing IPTV provider channels.
  Runs asynchronously to avoid blocking user requests.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Streamix.Iptv
  alias Streamix.Iptv.Provider

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}}) do
    case Iptv.get_provider(provider_id) do
      nil ->
        {:error, :provider_not_found}

      provider ->
        # Update status to syncing
        Iptv.update_provider(provider, %{sync_status: "syncing"})
        broadcast_sync_status(provider, "syncing")

        case Iptv.sync_provider(provider) do
          {:ok, count} ->
            # Update status to completed
            Iptv.update_provider(provider, %{sync_status: "completed"})
            broadcast_sync_status(provider, "completed", %{channels_count: count})
            :ok

          {:error, reason} ->
            # Update status to failed
            Iptv.update_provider(provider, %{sync_status: "failed"})
            broadcast_sync_status(provider, "failed", %{error: inspect(reason)})
            {:error, reason}
        end
    end
  end

  @doc """
  Enqueues a sync job for the given provider.
  Returns {:ok, job} or {:error, changeset}.
  """
  def enqueue(%Provider{} = provider) do
    %{provider_id: provider.id}
    |> new()
    |> Oban.insert()
  end

  def enqueue(provider_id) when is_integer(provider_id) or is_binary(provider_id) do
    %{provider_id: provider_id}
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
