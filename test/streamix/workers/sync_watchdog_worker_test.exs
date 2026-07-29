defmodule Streamix.Workers.SyncWatchdogWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.SyncWatchdogWorker
  alias Streamix.Workers.Torrent.SyncSourceWorker

  test "does not fail a torrent provider while a source job is in flight" do
    provider = torrent_provider()

    %{
      "provider_id" => provider.id,
      "source_slug" => "yts",
      "workflow_id" => Ecto.UUID.generate()
    }
    |> SyncSourceWorker.new()
    |> Oban.insert!()

    provider
    |> Ecto.Changeset.change(updated_at: stale_timestamp())
    |> Repo.update!()

    assert :ok = SyncWatchdogWorker.perform(%Oban.Job{})
    assert Repo.reload!(provider).sync_status == "syncing"
  end

  test "fails a stale torrent provider without any in-flight work" do
    provider = torrent_provider()

    provider
    |> Ecto.Changeset.change(updated_at: stale_timestamp())
    |> Repo.update!()

    assert :ok = SyncWatchdogWorker.perform(%Oban.Job{})
    assert Repo.reload!(provider).sync_status == "failed"
  end

  defp torrent_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "Torrent Watchdog Test",
      url: "torrent://watchdog-#{System.unique_integer([:positive])}",
      provider_type: :torrent,
      is_system: true,
      visibility: :global,
      sync_status: "syncing"
    })
    |> Repo.insert!()
  end

  defp stale_timestamp do
    DateTime.utc_now()
    |> DateTime.add(-2 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end
end
