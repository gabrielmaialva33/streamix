defmodule Streamix.Workers.SyncTorrentProviderWorker do
  @moduledoc """
  Top-level dispatcher for torrent provider ingestion.

  Loads (or creates) the system torrent provider, then enqueues one
  `Streamix.Workers.Torrent.SyncSourceWorker` job per source returned
  by `Streamix.Iptv.Torrent.sources/0`.

  Queue: `:torrent_sync`. Triggered nightly by the Oban cron plugin.
  Mirrors `Streamix.Workers.SyncGindexProviderWorker`.
  """

  use Oban.Worker, queue: :torrent_sync, max_attempts: 3

  alias Streamix.Iptv.{Provider, Torrent, TorrentProvider}
  alias Streamix.Repo
  alias Streamix.Workers.Torrent.SyncSourceWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if TorrentProvider.enabled?() do
      Logger.info("[Torrent Dispatcher] ensuring provider exists")

      case TorrentProvider.ensure_exists!() do
        {:ok, %Provider{} = provider} ->
          dispatch(provider)

        {:ok, :disabled} ->
          :ok

        {:error, reason} = err ->
          Logger.error("[Torrent Dispatcher] provider ensure failed: #{inspect(reason)}")
          err
      end
    else
      :ok
    end
  end

  defp dispatch(provider) do
    sources = Torrent.sources()

    Logger.info(
      "[Torrent Dispatcher] enqueuing #{length(sources)} sources for provider #{provider.id}"
    )

    mark_status(provider, "syncing")

    Enum.each(sources, fn module ->
      args = %{
        "provider_id" => provider.id,
        "source_slug" => module.slug()
      }

      case args |> SyncSourceWorker.new() |> Oban.insert() do
        {:ok, %Oban.Job{}} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Torrent Dispatcher] failed to enqueue #{module.slug()}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp mark_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end
end
