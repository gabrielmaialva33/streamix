defmodule Streamix.Workers.SyncTorrentProviderWorkerTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentTestSource
  alias Streamix.Workers.SyncTorrentProviderWorker
  alias Streamix.Workers.Torrent.{SyncOrchestratorWorker, SyncSourceWorker}

  setup do
    previous_provider = Application.get_env(:streamix, :torrent_provider)
    previous_sources = Application.get_env(:streamix, :torrent_sources)

    Application.put_env(:streamix, :torrent_provider, enabled: true)
    Application.put_env(:streamix, :torrent_sources, [TorrentTestSource])

    on_exit(fn ->
      restore_env(:torrent_provider, previous_provider)
      restore_env(:torrent_sources, previous_sources)
    end)

    :ok
  end

  test "does not start a workflow while a legacy source job is active" do
    provider = torrent_provider()

    %{"provider_id" => provider.id, "source_slug" => "test"}
    |> SyncSourceWorker.new()
    |> Oban.insert!()

    assert :ok = perform_job(SyncTorrentProviderWorker, %{})

    assert Repo.aggregate(Oban.Job, :count) == 1
    refute_enqueued(worker: SyncOrchestratorWorker)
  end

  test "starts a coordinated workflow when the provider is idle" do
    provider = torrent_provider()

    assert :ok = perform_job(SyncTorrentProviderWorker, %{})

    assert_enqueued(
      worker: SyncSourceWorker,
      args: %{"provider_id" => provider.id, "source_slug" => "test"}
    )

    assert_enqueued(
      worker: SyncOrchestratorWorker,
      args: %{"provider_id" => provider.id, "total_sources" => 1}
    )

    assert Repo.reload!(provider).sync_status == "syncing"
  end

  defp torrent_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "Torrent Aggregator",
      url: "torrent://aggregator",
      provider_type: :torrent,
      is_system: true,
      visibility: :global,
      is_active: true
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:streamix, key)
  defp restore_env(key, value), do: Application.put_env(:streamix, key, value)
end
