defmodule Streamix.Workers.Gindex.ScanRootWorkerTest do
  use Streamix.DataCase, async: false

  alias Streamix.Gindex
  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.Workers.Gindex.ScanRootWorker

  setup do
    original = Application.get_env(:streamix, Streamix.Gindex.QuotaGuard)
    quota_key = "gindex:quota:#{Date.utc_today()}"

    Application.put_env(:streamix, Streamix.Gindex.QuotaGuard,
      daily_limit: 10,
      playback_reserve: 2
    )

    Redix.command!(:streamix_redis, ["DEL", quota_key])

    on_exit(fn ->
      Redix.command!(:streamix_redis, ["DEL", quota_key])

      if original do
        Application.put_env(:streamix, Streamix.Gindex.QuotaGuard, original)
      else
        Application.delete_env(:streamix, Streamix.Gindex.QuotaGuard)
      end
    end)

    %{quota_key: quota_key}
  end

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
      |> Map.put("base_url", "https://new-gindex.example/")
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

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "paused"
    assert root.paused_reason == "quota_exhausted"
    assert root.cursor["folder_path"] == "/1:/Series/B/"
  end

  test "pauses before starting a scan when only the playback reserve remains", %{
    quota_key: quota_key
  } do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)
    Redix.command!(:streamix_redis, ["SET", quota_key, "8", "EX", "60"])

    sync_fun = fn _provider, _base_url, _path, _kind, _opts ->
      flunk("background sync must not enter the playback reserve")
    end

    assert {:snooze, 123} = ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "paused"
    assert root.paused_reason == "quota_exhausted"
    assert root.quota_count == 8
  end

  test "defers a scan when the remaining background budget cannot make durable progress", %{
    quota_key: quota_key
  } do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)

    Application.put_env(:streamix, Streamix.Gindex.QuotaGuard,
      daily_limit: 10_000,
      playback_reserve: 1_000
    )

    Redix.command!(:streamix_redis, ["SET", quota_key, "8501", "EX", "60"])

    sync_fun = fn _provider, _base_url, _path, _kind, _opts ->
      flunk("an unproductive slice must wait for the next quota window")
    end

    assert {:snooze, 123} = ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "paused"
    assert root.paused_reason == "insufficient_budget"
    assert root.quota_count == 8_501
    assert Gindex.scan_cycle_summary(provider.id, root.cycle_id).roots_paused_quota == 1
    assert Repo.reload!(provider).sync_status == "paused_quota"
  end

  test "turns an upstream 429 into a durable pause instead of an inline retry" do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)

    sync_fun = fn _provider, _base_url, ^path, :series, _opts ->
      {:error, {:rate_limited, 429, 90}}
    end

    assert {:snooze, 90} = ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "paused"
    assert root.paused_reason == "upstream_rate_limited"
    assert DateTime.diff(root.next_resume_at, DateTime.utc_now(), :second) in 85..90
    assert Repo.reload!(provider).sync_status == "paused_upstream"
  end

  test "persists ordinary retry timing so the orchestrator does not busy-poll" do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = %{insert_scan_job(provider, path) | attempt: 8}

    sync_fun = fn _provider, _base_url, ^path, :series, _opts ->
      {:error, :upstream_unavailable}
    end

    before_retry = DateTime.utc_now()

    assert {:error, :upstream_unavailable} =
             ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    root = Gindex.get_scan_root(provider.id, path, :series)
    retry_delay = DateTime.diff(root.next_resume_at, before_retry, :second)

    assert root.status == "paused"
    assert root.paused_reason == "retryable_error"
    assert retry_delay in 270..300
  end

  test "persists nested partial-listing failures as JSON-safe retry state" do
    provider = gindex_provider()
    path = "/1:/Series/"
    job = insert_scan_job(provider, path)

    reason =
      {:partial_listing,
       %{
         path: path,
         page: 4,
         items: [%{name: "partial item"}],
         items_collected: 400,
         reason:
           {:all_endpoints_failed,
            [
              %{endpoint: "https://gindex.example", reason: {:rate_limited, 429, 7_200}},
              %{endpoint: "https://fallback.example", reason: {:http_error, 500}}
            ]}
       }}

    sync_fun = fn _provider, _base_url, ^path, :series, _opts ->
      {:error, reason}
    end

    assert {:error, ^reason} =
             ScanRootWorker.perform_with(job, sync_fun, fn -> 123 end)

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "paused"
    assert root.paused_reason == "retryable_error"
    refute Map.has_key?(root.last_error["details"], "items")

    assert root.last_error["details"]["reason"] == [
             "all_endpoints_failed",
             [
               %{
                 "endpoint" => "https://gindex.example",
                 "reason" => ["rate_limited", 429, 7_200]
               },
               %{
                 "endpoint" => "https://fallback.example",
                 "reason" => ["http_error", 500]
               }
             ]
           ]
  end

  test "pulls a legacy retryable job forward when durable state says it is ready" do
    provider = gindex_provider()
    path = "/1:/Series/"
    original = insert_scan_job(provider, path)
    tomorrow = DateTime.add(DateTime.utc_now(), 86_400, :second)

    original
    |> Ecto.Changeset.change(state: "retryable", scheduled_at: tomorrow)
    |> Repo.update!()

    replacement =
      original.args
      |> ScanRootWorker.new(schedule_in: 0)
      |> Oban.insert!()

    assert replacement.conflict?
    assert replacement.id == original.id
    assert DateTime.diff(replacement.scheduled_at, DateTime.utc_now(), :second) in -1..1
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

    root = Gindex.get_scan_root(provider.id, path, :series)
    assert root.status == "completed"
    assert root.cursor == %{}
    assert root.stats == %{"series_count" => 4, "episodes_count" => 20}
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
