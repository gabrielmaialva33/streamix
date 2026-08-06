defmodule Streamix.Workers.Gindex.SyncOrchestratorWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.SyncOrchestratorWorker

  test "finalizes from durable roots after Oban rows have been pruned" do
    provider = gindex_provider()
    cycle = create_cycle(provider)

    Enum.each(cycle.roots, fn root ->
      assert {:ok, _root} = Gindex.fail_scan_root(root, :upstream_unavailable)
    end)

    Repo.delete_all(Oban.Job)

    assert :ok = SyncOrchestratorWorker.perform(orchestrator_job(provider, cycle.cycle_id))
    assert Repo.reload!(provider).sync_status == "failed"
  end

  test "recreates missing jobs while durable roots are unfinished" do
    provider = gindex_provider()
    cycle = create_cycle(provider)
    Repo.delete_all(Oban.Job)

    assert {:snooze, 30} =
             SyncOrchestratorWorker.perform(orchestrator_job(provider, cycle.cycle_id, 120))

    assert Repo.reload!(provider).sync_status == "syncing"

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "Streamix.Workers.Gindex.ScanRootWorker"
             ),
             :count
           ) == length(cycle.roots)
  end

  test "keeps quota-paused roots honest and sleeps until their resume window" do
    provider = gindex_provider()
    cycle = create_cycle(provider)
    next_resume_at = DateTime.add(DateTime.utc_now(), 600, :second)

    Enum.each(cycle.roots, fn root ->
      assert {:ok, _root} =
               Gindex.pause_scan_root(root, :quota_exhausted,
                 quota_count: 8_000,
                 next_resume_at: next_resume_at
               )
    end)

    assert {:snooze, delay} =
             SyncOrchestratorWorker.perform(orchestrator_job(provider, cycle.cycle_id, 281))

    assert delay > 500
    assert delay <= 605
    assert Repo.reload!(provider).sync_status == "paused_quota"
  end

  test "finalizes as partial when a completed root skipped upstream folders" do
    provider = gindex_provider()
    cycle = create_cycle(provider)

    [skipped_root | remaining_roots] = cycle.roots

    assert {:ok, _root} =
             Gindex.complete_scan_root(skipped_root, %{movies_count: 5, skipped_count: 1})

    Enum.each(remaining_roots, fn root ->
      assert {:ok, _root} = Gindex.complete_scan_root(root, %{})
    end)

    assert :ok = SyncOrchestratorWorker.perform(orchestrator_job(provider, cycle.cycle_id))
    assert Repo.reload!(provider).sync_status == "partial"
  end

  defp create_cycle(provider) do
    cycle_id = Ecto.UUID.generate()
    roots = Gindex.sync_roots_for(provider, ~D[2026-08-06])
    {:ok, cycle} = Gindex.ensure_scan_cycle(provider.id, roots, cycle_id: cycle_id)
    cycle
  end

  defp orchestrator_job(provider, cycle_id, attempt \\ 1) do
    %Oban.Job{
      args: %{
        "provider_id" => provider.id,
        "workflow_id" => cycle_id,
        "total_roots" => 6
      },
      attempt: attempt
    }
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Orchestrator Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global,
      sync_status: "syncing"
    })
    |> Repo.insert!()
  end
end
