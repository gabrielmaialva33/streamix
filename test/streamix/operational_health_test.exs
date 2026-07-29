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
end
