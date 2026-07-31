defmodule Streamix.Iptv.Streaming.ProviderRuntimeTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.ProviderCapabilities
  alias Streamix.Iptv.Streaming.ProviderRuntime

  setup do
    ProviderRuntime.reset()
    on_exit(&ProviderRuntime.reset/0)
  end

  test "budgets leases against the account max_connections" do
    provider_id = 101
    ProviderRuntime.put_capabilities(provider_id, capabilities(max_connections: 2))

    assert {:ok, first} = ProviderRuntime.acquire(provider_id, :vod)
    assert {:ok, second} = ProviderRuntime.acquire(provider_id, :live)
    assert {:error, :capacity_exhausted} = ProviderRuntime.acquire(provider_id, :vod)

    assert %{capacity: %{available: 0, leased_connections: 2}} =
             ProviderRuntime.snapshot(provider_id)

    assert :ok = ProviderRuntime.release(first)

    assert %{capacity: %{available: 1, leased_connections: 1}} =
             ProviderRuntime.snapshot(provider_id)

    ProviderRuntime.release(second)
  end

  test "reserves observed external connections without double counting owned leases" do
    provider_id = 102

    ProviderRuntime.put_capabilities(
      provider_id,
      capabilities(max_connections: 2, active_connections: 1)
    )

    assert {:ok, lease} = ProviderRuntime.acquire(provider_id, :vod)
    assert {:error, :capacity_exhausted} = ProviderRuntime.acquire(provider_id, :vod)

    assert %{
             capacity: %{
               observed_active_connections: 1,
               external_active_connections: 1,
               leased_connections: 1
             }
           } =
             ProviderRuntime.snapshot(provider_id)

    ProviderRuntime.release(lease)
  end

  test "subtracts owned leases from a fresh upstream active connection sample" do
    provider_id = 105

    assert {:ok, first_lease} = ProviderRuntime.acquire(provider_id, :vod)

    ProviderRuntime.put_capabilities(
      provider_id,
      capabilities(max_connections: 2, active_connections: 1)
    )

    assert %{capacity: %{external_active_connections: 0, available: 1}} =
             ProviderRuntime.snapshot(provider_id)

    assert {:ok, second_lease} = ProviderRuntime.acquire(provider_id, :vod)
    ProviderRuntime.release(first_lease)
    ProviderRuntime.release(second_lease)
  end

  test "automatically releases leases when their owner exits" do
    provider_id = 103
    ProviderRuntime.put_capabilities(provider_id, capabilities(max_connections: 1))

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner_monitor = Process.monitor(owner)

    assert {:ok, _lease} = ProviderRuntime.acquire(provider_id, :live, owner)
    assert %{capacity: %{available: 0}} = ProviderRuntime.snapshot(provider_id)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    assert_eventually_available(provider_id)
  end

  test "tracks control, live and VOD health independently" do
    provider_id = 104

    ProviderRuntime.record_success(provider_id, :control, 100)
    ProviderRuntime.record_success(provider_id, :control, 200)
    ProviderRuntime.record_failure(provider_id, :vod, {:unexpected_status, 503})

    snapshot = ProviderRuntime.snapshot(provider_id)

    assert snapshot.dimensions.control.status == :healthy
    assert_in_delta snapshot.dimensions.control.ewma_latency_ms, 130.0, 0.01
    assert snapshot.dimensions.live.status == :unknown
    assert snapshot.dimensions.vod.status == :degraded
    assert snapshot.dimensions.vod.last_error == %{kind: :http_status, status: 503}

    ProviderRuntime.record_failure(provider_id, :vod, :timeout)
    ProviderRuntime.record_failure(provider_id, :vod, :timeout)

    assert ProviderRuntime.snapshot(provider_id).dimensions.vod.status == :unhealthy
  end

  defp capabilities(overrides) do
    struct!(ProviderCapabilities, [authenticated?: true, active?: true] ++ overrides)
  end

  defp assert_eventually_available(provider_id, attempts \\ 20)

  defp assert_eventually_available(provider_id, 0) do
    assert %{capacity: %{available: 1, leased_connections: 0}} =
             ProviderRuntime.snapshot(provider_id)
  end

  defp assert_eventually_available(provider_id, attempts) do
    case ProviderRuntime.snapshot(provider_id) do
      %{capacity: %{available: 1, leased_connections: 0}} ->
        :ok

      _ ->
        receive do
        after
          1 -> assert_eventually_available(provider_id, attempts - 1)
        end
    end
  end
end
