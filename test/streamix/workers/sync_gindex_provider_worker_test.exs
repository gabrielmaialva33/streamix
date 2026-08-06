defmodule Streamix.Workers.SyncGindexProviderWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
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
