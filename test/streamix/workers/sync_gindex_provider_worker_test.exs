defmodule Streamix.Workers.SyncGindexProviderWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker
  alias Streamix.Workers.SyncGindexProviderWorker

  test "reconciles a requested cycle from its durable roots, not current configuration" do
    provider = gindex_provider()
    old_cycle_id = Ecto.UUID.generate()

    assert {:ok, old_cycle} =
             Gindex.ensure_scan_cycle(
               provider.id,
               [%{base_url: provider.gindex_url, path: "/legacy/", kind: :movies}],
               cycle_id: old_cycle_id
             )

    current_roots = Gindex.sync_roots_for(provider, ~D[2026-08-06])
    assert {:ok, current_cycle} = Gindex.ensure_scan_cycle(provider.id, current_roots)
    refute current_cycle.cycle_id == old_cycle.cycle_id

    assert :ok =
             SyncGindexProviderWorker.dispatch(provider, cycle_id: old_cycle.cycle_id)

    assert Enum.all?(
             Gindex.list_scan_cycle(provider.id, current_cycle.cycle_id),
             &(&1.cycle_id == current_cycle.cycle_id)
           )

    assert [%Oban.Job{args: args}] =
             Repo.all(
               from(job in Oban.Job,
                 where: job.worker == "Streamix.Workers.Gindex.ScanRootWorker"
               )
             )

    assert args["workflow_id"] == old_cycle.cycle_id
    assert args["path"] == "/legacy/"
  end

  test "migrates the newest in-flight legacy workflow into durable scan state" do
    provider = gindex_provider()
    old_cycle_id = Ecto.UUID.generate()
    cycle_id = Ecto.UUID.generate()
    checkpoint = %{"category_index" => 3, "page_token" => "next-page"}
    now = DateTime.utc_now()

    insert_legacy_job(
      provider,
      "/0:/Filmes/",
      old_cycle_id,
      DateTime.add(now, -60, :second),
      %{"page_token" => "stale-page"}
    )

    insert_legacy_job(provider, "/1:/Filmes/", cycle_id, now, checkpoint)

    assert :ok = SyncGindexProviderWorker.dispatch(provider)
    assert Gindex.active_scan_cycle_id(provider.id) == cycle_id

    assert %{cycle_id: ^cycle_id, cursor: ^checkpoint} =
             Gindex.get_scan_root(provider.id, "/1:/Filmes/", :movies)
  end

  test "reopens failed roots on an explicit dispatch without losing their cursor" do
    provider = gindex_provider()
    roots = Gindex.sync_roots_for(provider)

    assert {:ok, cycle} = Gindex.ensure_scan_cycle(provider.id, roots)
    [failed_root, active_root | _rest] = cycle.roots

    checkpoint = %{
      "root_path" => failed_root.root_path,
      "category_path" => "/1:/Filmes/2026/",
      "item_path" => "/1:/Filmes/2026/B.mkv"
    }

    assert {:ok, failed_root} = Gindex.checkpoint_scan_root(failed_root, checkpoint)
    assert {:ok, _failed_root} = Gindex.fail_scan_root(failed_root, :upstream_unavailable)
    assert {:ok, _active_root} = Gindex.pause_scan_root(active_root, :slice_exhausted)

    assert :ok = SyncGindexProviderWorker.dispatch(provider)

    reopened = Gindex.get_scan_root(provider.id, failed_root.root_path, failed_root.kind)
    assert reopened.status == "pending"
    assert reopened.cursor == checkpoint
    assert reopened.attempt_count == 0
    assert reopened.last_error == nil
    assert reopened.completed_at == nil

    assert Repo.exists?(
             from(job in Oban.Job,
               where: job.worker == "Streamix.Workers.Gindex.ScanRootWorker",
               where: fragment("?->>'path' = ?", job.args, ^failed_root.root_path),
               where: fragment("?->>'workflow_id' = ?", job.args, ^cycle.cycle_id)
             )
           )
  end

  defp insert_legacy_job(provider, path, cycle_id, inserted_at, checkpoint) do
    args = %{
      "provider_id" => provider.id,
      "base_url" => provider.gindex_url,
      "path" => path,
      "kind" => "movies",
      "workflow_id" => cycle_id
    }

    {:ok, job} =
      args
      |> ScanRootWorker.new(meta: %{"checkpoint" => checkpoint})
      |> Oban.insert()

    job
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Dispatcher Test",
      url: "https://gindex-dispatcher.example/",
      gindex_url: "https://gindex-dispatcher.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global,
      sync_status: "syncing"
    })
    |> Repo.insert!()
  end
end
