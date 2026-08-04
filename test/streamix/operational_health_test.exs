defmodule Streamix.OperationalHealthTest do
  use Streamix.DataCase, async: false

  alias Streamix.OperationalHealth

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
    assert snapshot.release.version == "0.0.100"
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
             state: :paused,
             count: 8_000,
             limit: 8_000,
             remaining: 0,
             resumes_in_seconds: resumes_in_seconds
           } = snapshot.checks.gindex

    assert resumes_in_seconds in 1..86_405
  end
end
