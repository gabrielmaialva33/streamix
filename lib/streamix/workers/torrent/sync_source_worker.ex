defmodule Streamix.Workers.Torrent.SyncSourceWorker do
  @moduledoc """
  Oban worker that runs `Streamix.Iptv.Torrent.Sync.sync_source/2`
  for a single `{provider_id, source_slug}` pair.

  Queue: `:torrent_sync`. Triggered by
  `Streamix.Workers.SyncTorrentProviderWorker`, one job per enabled
  source so a single misbehaving source can't sabotage the whole
  catalog.
  """

  use Oban.Worker, queue: :torrent_sync, max_attempts: 3

  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Torrent
  alias Streamix.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id, "source_slug" => source_slug}}) do
    with %Provider{provider_type: :torrent} = provider <- Repo.get(Provider, provider_id),
         module when is_atom(module) and not is_nil(module) <- Torrent.source_for(source_slug) do
      case Torrent.sync_source(provider, module) do
        {:ok, stats} ->
          Logger.info(
            "[Torrent SyncSource] provider=#{provider_id} slug=#{source_slug} ok " <>
              "movies=#{stats.movies} torrents=#{stats.torrents}"
          )

          :ok

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

      %Provider{} ->
        {:error, :not_torrent_provider}
    end
  end
end
