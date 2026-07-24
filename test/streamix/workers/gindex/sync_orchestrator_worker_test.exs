defmodule Streamix.Workers.Gindex.SyncOrchestratorWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.{ScanRootWorker, SyncOrchestratorWorker}

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

  test "marks the provider failed when every scan root was discarded" do
    provider = gindex_provider()
    workflow_id = Ecto.UUID.generate()

    scan_job =
      %{
        "provider_id" => provider.id,
        "base_url" => provider.gindex_url,
        "path" => "/0:/Animes/",
        "kind" => "animes",
        "workflow_id" => workflow_id
      }
      |> ScanRootWorker.new()
      |> Oban.insert!()

    scan_job
    |> Ecto.Changeset.change(
      state: "discarded",
      attempt: scan_job.max_attempts,
      discarded_at: DateTime.utc_now()
    )
    |> Repo.update!()

    job = %Oban.Job{
      args: %{
        "provider_id" => provider.id,
        "workflow_id" => workflow_id,
        "total_roots" => 1
      },
      attempt: 1
    }

    assert :ok = SyncOrchestratorWorker.perform(job)
    assert Repo.reload!(provider).sync_status == "failed"
  end
end
