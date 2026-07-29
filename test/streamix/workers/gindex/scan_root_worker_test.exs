defmodule Streamix.Workers.Gindex.ScanRootWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker

  test "keeps a root unique across workflow ids while it is active" do
    base_args = %{
      "provider_id" => 42,
      "base_url" => "https://gindex.example/",
      "path" => "/0:/Animes/",
      "kind" => "animes"
    }

    first =
      base_args
      |> Map.put("workflow_id", Ecto.UUID.generate())
      |> ScanRootWorker.new()
      |> Oban.insert!()

    duplicate =
      base_args
      |> Map.put("workflow_id", Ecto.UUID.generate())
      |> ScanRootWorker.new()
      |> Oban.insert!()

    refute first.conflict?
    assert duplicate.conflict?
    assert duplicate.id == first.id
  end

  test "persists a JSONB checkpoint before snoozing on quota exhaustion" do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)

    sync_fun = fn _provider, _base_url, ^path, :series, opts ->
      assert opts[:checkpoint] == nil

      assert :ok =
               opts[:on_checkpoint].(%{
                 "root_path" => path,
                 "folder_path" => "/1:/Series/B/"
               })

      {:error, {:quota_exhausted, 8_000}}
    end

    assert {:snooze, 123} =
             ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    meta = Repo.get!(Oban.Job, job.id).meta

    assert meta["series_checkpoint"] == %{
             "root_path" => path,
             "folder_path" => "/1:/Series/B/"
           }

    assert meta["checkpoint_path"] == path
    assert meta["paused_reason"] == "quota_exhausted"
    assert meta["quota_count"] == 8_000
  end

  test "preserves checkpoint writes during the run and clears them after success" do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)

    sync_fun = fn _provider, _base_url, ^path, :series, opts ->
      assert :ok =
               opts[:on_checkpoint].(%{
                 "root_path" => path,
                 "folder_path" => "/1:/Series/Z/"
               })

      {:ok, %{series_count: 4, episodes_count: 20}}
    end

    assert :ok = ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    meta = Repo.get!(Oban.Job, job.id).meta
    assert meta["stats"] == %{"series_count" => 4, "episodes_count" => 20}
    assert meta["series_checkpoint"] == nil
    assert meta["checkpoint_path"] == nil
    assert meta["paused_reason"] == nil
    assert meta["quota_count"] == nil
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Scan Root Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global,
      sync_status: "syncing"
    })
    |> Repo.insert!()
  end

  defp insert_scan_job(provider, path) do
    job =
      %{
        "provider_id" => provider.id,
        "base_url" => provider.gindex_url,
        "path" => path,
        "kind" => "series",
        "workflow_id" => Ecto.UUID.generate()
      }
      |> ScanRootWorker.new()
      |> Oban.insert!()

    assert job.max_attempts == 12
    job
  end
end
