defmodule Streamix.OperationalHealthTest do
  use Streamix.DataCase, async: false

  alias Streamix.Gindex.{EndpointPolicy, HealthTracker}
  alias Streamix.OperationalHealth

  @version Path.expand("../../VERSION", __DIR__) |> File.read!() |> String.trim()

  import Streamix.IptvFixtures

  test "reports failed public provider syncs as degraded without failing readiness" do
    global_provider_fixture(%{sync_status: "failed"})

    snapshot = OperationalHealth.snapshot()

    assert snapshot.status == :degraded
    assert snapshot.checks.database.status == :ok
    assert is_binary(snapshot.checks.database.migration)
    assert snapshot.checks.redis.status == :ok
    assert snapshot.checks.providers.status == :degraded
    assert snapshot.checks.providers.counts["failed"] == 1
    assert snapshot.checks.semantic_search.status == :disabled
    assert snapshot.checks.torrent.status == :disabled
    assert snapshot.release.version == @version
    assert is_binary(snapshot.release.revision)
    assert is_binary(snapshot.release.asset_version)
  end

  test "reports an exhausted GIndex quota as a degraded paused subsystem" do
    quota_key = "gindex:quota:#{Date.utc_today()}"
    {:ok, "OK"} = Redix.command(:streamix_redis, ["SET", quota_key, "8000", "EX", "60"])

    on_exit(fn -> Redix.command(:streamix_redis, ["DEL", quota_key]) end)

    snapshot = OperationalHealth.snapshot()

    assert snapshot.status == :degraded

    assert %{
             status: :degraded,
             state: :playback_unavailable,
             sync_state: :paused,
             playback_state: :unavailable,
             count: 8_000,
             limit: 8_000,
             remaining: 0,
             resumes_in_seconds: resumes_in_seconds
           } = snapshot.checks.gindex

    assert resumes_in_seconds in 1..86_405
  end

  test "distinguishes a paused background sync from available playback" do
    quota_key = "gindex:quota:#{Date.utc_today()}"
    original = Application.get_env(:streamix, Streamix.Gindex.QuotaGuard)

    Application.put_env(:streamix, Streamix.Gindex.QuotaGuard,
      daily_limit: 10,
      playback_reserve: 2
    )

    {:ok, "OK"} = Redix.command(:streamix_redis, ["SET", quota_key, "8", "EX", "60"])

    on_exit(fn ->
      Redix.command(:streamix_redis, ["DEL", quota_key])

      if original do
        Application.put_env(:streamix, Streamix.Gindex.QuotaGuard, original)
      else
        Application.delete_env(:streamix, Streamix.Gindex.QuotaGuard)
      end
    end)

    snapshot = OperationalHealth.snapshot()

    assert snapshot.status == :degraded

    assert %{
             status: :degraded,
             state: :background_paused,
             sync_state: :paused,
             playback_state: :available,
             background_limit: 8,
             background_remaining: 0,
             playback_reserve: 2,
             remaining: 2
           } = snapshot.checks.gindex
  end

  test "keeps playback available while one verified fallback remains healthy" do
    [primary | _fallbacks] = stream_urls = EndpointPolicy.stream_urls()
    endpoints = endpoint_tuples(stream_urls)

    on_exit(fn -> HealthTracker.reset_all(endpoints) end)

    for _ <- 1..3 do
      assert {:ok, _state} = HealthTracker.record_error(primary, :stream, :rate_limited)
    end

    snapshot = OperationalHealth.snapshot()

    assert snapshot.checks.gindex.playback_state == :available
    assert snapshot.checks.gindex.upstream.playback.state == :available
  end

  test "reports playback unavailable only after every verified mirror is unhealthy" do
    stream_urls = EndpointPolicy.stream_urls()
    endpoints = endpoint_tuples(stream_urls)

    on_exit(fn -> HealthTracker.reset_all(endpoints) end)

    for stream_url <- stream_urls, _attempt <- 1..3 do
      assert {:ok, _state} = HealthTracker.record_error(stream_url, :stream, :rate_limited)
    end

    snapshot = OperationalHealth.snapshot()

    assert snapshot.status == :degraded
    assert snapshot.checks.gindex.state == :playback_unavailable
    assert snapshot.checks.gindex.playback_state == :unavailable

    assert snapshot.checks.gindex.upstream.playback == %{
             state: :unavailable,
             errors: 3 * length(stream_urls),
             candidates: length(stream_urls)
           }
  end

  defp endpoint_tuples(urls) do
    urls
    |> Enum.with_index(1)
    |> Enum.map(fn {url, priority} -> {:stream, url, priority} end)
  end
end
