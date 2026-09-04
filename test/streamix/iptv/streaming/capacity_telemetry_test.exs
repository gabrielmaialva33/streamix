defmodule Streamix.Iptv.Streaming.CapacityTelemetryTest do
  # Attaches a named global handler and reads a shared ETS table.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Iptv.Streaming.CapacityTelemetry

  setup do
    :ok = CapacityTelemetry.setup()
    :ok
  end

  test "a refusal is logged with the cause that produced it" do
    log =
      capture_log(fn ->
        CapacityTelemetry.refused(:live, provider_id: 3, content_id: 42, media_type: "channel")
      end)

    assert log =~ "cause=live"
    assert log =~ "provider=3"
    assert log =~ "content=42"
  end

  test "each cause is counted separately" do
    before = CapacityTelemetry.summary()

    capture_log(fn ->
      CapacityTelemetry.refused(:live, provider_id: 3)
      CapacityTelemetry.refused(:live, provider_id: 3)
      CapacityTelemetry.refused(:gindex_quota)
    end)

    now = CapacityTelemetry.summary()

    assert now[:live] - Map.get(before, :live, 0) == 2
    assert now[:gindex_quota] - Map.get(before, :gindex_quota, 0) == 1
  end

  test "an unknown cause is bucketed instead of crashing the handler" do
    before = Map.get(CapacityTelemetry.summary(), :unknown, 0)

    log = capture_log(fn -> CapacityTelemetry.refused(:something_else) end)

    assert log =~ "cause=unknown"
    assert Map.get(CapacityTelemetry.summary(), :unknown, 0) - before == 1
  end

  test "setup is idempotent and does not double-attach the handler" do
    :ok = CapacityTelemetry.setup()
    :ok = CapacityTelemetry.setup()

    before = Map.get(CapacityTelemetry.summary(), :vod, 0)
    capture_log(fn -> CapacityTelemetry.refused(:vod, provider_id: 4) end)

    # A duplicated attach would count the same refusal twice.
    assert Map.get(CapacityTelemetry.summary(), :vod, 0) - before == 1
  end
end
