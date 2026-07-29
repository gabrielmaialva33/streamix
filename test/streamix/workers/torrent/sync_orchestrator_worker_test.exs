defmodule Streamix.Workers.Torrent.SyncOrchestratorWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Torrent.{SyncOrchestratorWorker, SyncSourceWorker}

  test "waits while a source is still in flight" do
    provider = torrent_provider()
    workflow_id = Ecto.UUID.generate()

    source_job(provider, workflow_id, "source-a")

    assert {:snooze, 30} =
             SyncOrchestratorWorker.perform(orchestrator_job(provider, workflow_id))

    assert Repo.reload!(provider).sync_status == "syncing"
  end

  test "marks a mixed workflow partial after every source settles" do
    provider = torrent_provider()
    workflow_id = Ecto.UUID.generate()

    source_job(provider, workflow_id, "source-a")
    |> settle("completed")

    source_job(provider, workflow_id, "source-b")
    |> settle("discarded")

    assert :ok =
             SyncOrchestratorWorker.perform(orchestrator_job(provider, workflow_id))

    refreshed = Repo.reload!(provider)
    assert refreshed.sync_status == "partial"
    assert refreshed.movies_count == 0
    assert refreshed.vod_synced_at
  end

  test "marks a workflow failed when no source completed" do
    provider = torrent_provider()
    workflow_id = Ecto.UUID.generate()

    source_job(provider, workflow_id, "source-a")
    |> settle("discarded")

    assert :ok =
             SyncOrchestratorWorker.perform(orchestrator_job(provider, workflow_id))

    assert Repo.reload!(provider).sync_status == "failed"
  end

  defp source_job(provider, workflow_id, slug) do
    %{
      "provider_id" => provider.id,
      "source_slug" => slug,
      "workflow_id" => workflow_id
    }
    |> SyncSourceWorker.new()
    |> Oban.insert!()
  end

  defp settle(job, state) do
    attrs =
      if state == "discarded" do
        %{
          state: state,
          attempt: job.max_attempts,
          discarded_at: DateTime.utc_now()
        }
      else
        %{state: state, completed_at: DateTime.utc_now()}
      end

    job
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp orchestrator_job(provider, workflow_id) do
    %Oban.Job{
      args: %{
        "provider_id" => provider.id,
        "workflow_id" => workflow_id,
        "total_sources" => 2,
        "dispatch_failures" => 0
      }
    }
  end

  defp torrent_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "Torrent Orchestrator Test",
      url: "torrent://orchestrator-#{System.unique_integer([:positive])}",
      provider_type: :torrent,
      is_system: true,
      visibility: :global,
      sync_status: "syncing"
    })
    |> Repo.insert!()
  end
end
