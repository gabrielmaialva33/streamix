defmodule Streamix.Workers.SyncEmbedplayProviderWorkerTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo

  import ExUnit.CaptureLog

  alias Streamix.Providers
  alias Streamix.Workers.SyncEmbedplayProviderWorker

  setup do
    original = Application.get_env(:streamix, :embedplay, [])
    request_options = Application.get_env(:streamix, :embedplay_catalog_request_options)
    Application.put_env(:streamix, :embedplay, enabled: true)

    Application.put_env(:streamix, :embedplay_catalog_request_options,
      plug: {Req.Test, __MODULE__}
    )

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :catalog_requested)

      Req.Test.json(conn, %{
        status: "success",
        results: %{movies: [%{tmdb_id: "603", imdb_id: "tt0133093"}]}
      })
    end)

    on_exit(fn ->
      Application.put_env(:streamix, :embedplay, original)
      Application.put_env(:streamix, :embedplay_catalog_request_options, request_options || [])
    end)

    {:ok, _provider} = Providers.ensure_embedplay_provider()
    :ok
  end

  test "syncs the catalog while resolution is healthy" do
    assert :ok = perform_job(SyncEmbedplayProviderWorker, %{})

    assert_received :catalog_requested
    assert %{movies_count: 1, sync_status: "completed"} = Providers.get_embedplay_provider()
  end

  test "skips with a log line while resolution is degraded" do
    {:ok, _provider} = Providers.mark_embedplay_degraded(:resolver_outdated)
    Logger.put_module_level(SyncEmbedplayProviderWorker, :info)
    on_exit(fn -> Logger.delete_module_level(SyncEmbedplayProviderWorker) end)

    log = capture_log(fn -> assert :ok = perform_job(SyncEmbedplayProviderWorker, %{}) end)

    assert log =~ "catalog sync skipped: provider degraded (reason=resolver_outdated)"
    refute_received :catalog_requested
    assert %{movies_count: 0, vod_synced_at: nil} = Providers.get_embedplay_provider()
  end

  test "is a no-op while Embedplay is disabled" do
    Application.put_env(:streamix, :embedplay, enabled: false)

    assert :ok = perform_job(SyncEmbedplayProviderWorker, %{})
    refute_received :catalog_requested
  end

  test "is scheduled daily by the crontab" do
    crontab =
      :streamix
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _plugin -> nil
      end)

    assert {"43 6 * * *", SyncEmbedplayProviderWorker} in crontab
    assert {"17,47 * * * *", Streamix.Workers.EmbedplayCanaryWorker} in crontab
  end
end
