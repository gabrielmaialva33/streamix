defmodule Streamix.Workers.SyncWatchdogWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex
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

  test "does not fail a GIndex cycle intentionally paused by the daily quota" do
    provider = gindex_provider()
    cycle_id = Ecto.UUID.generate()
    roots = Gindex.sync_roots_for(provider, ~D[2026-08-06])

    assert {:ok, cycle} =
             Gindex.ensure_scan_cycle(provider.id, roots, cycle_id: cycle_id)

    next_resume_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    Enum.each(cycle.roots, fn root ->
      assert {:ok, _root} =
               Gindex.pause_scan_root(root, :quota_exhausted,
                 quota_count: 8_000,
                 next_resume_at: next_resume_at
               )
    end)

    provider
    |> Provider.sync_changeset(%{sync_status: "paused_quota"})
    |> Ecto.Changeset.force_change(:updated_at, stale_timestamp())
    |> Repo.update!()

    assert :ok = SyncWatchdogWorker.perform(%Oban.Job{})
    assert Repo.reload!(provider).sync_status == "paused_quota"
  end

  test "does not fail a GIndex cycle intentionally paused by upstream rate limiting" do
    provider = gindex_provider()
    cycle_id = Ecto.UUID.generate()
    roots = Gindex.sync_roots_for(provider, ~D[2026-08-06])

    assert {:ok, cycle} =
             Gindex.ensure_scan_cycle(provider.id, roots, cycle_id: cycle_id)

    next_resume_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    Enum.each(cycle.roots, fn root ->
      assert {:ok, _root} =
               Gindex.pause_scan_root(root, :upstream_rate_limited,
                 error: {:rate_limited, 429, 3_600},
                 next_resume_at: next_resume_at
               )
    end)

    provider
    |> Provider.sync_changeset(%{sync_status: "paused_upstream"})
    |> Ecto.Changeset.force_change(:updated_at, stale_timestamp())
    |> Repo.update!()

    assert :ok = SyncWatchdogWorker.perform(%Oban.Job{})
    assert Repo.reload!(provider).sync_status == "paused_upstream"
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

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Watchdog Test",
      url: "https://gindex-watchdog.example/",
      gindex_url: "https://gindex-watchdog.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global,
      sync_status: "paused_quota"
    })
    |> Repo.insert!()
  end

  defp stale_timestamp do
    DateTime.utc_now()
    |> DateTime.add(-2 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end
end
