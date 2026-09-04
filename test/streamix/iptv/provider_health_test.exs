defmodule Streamix.Iptv.ProviderHealthTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{ProviderCapabilities, ProviderHealth, XtreamCircuitBreaker}
  alias Streamix.Iptv.Streaming.ProviderRuntime

  setup do
    ProviderRuntime.reset()
    XtreamCircuitBreaker.reset_all()

    on_exit(fn ->
      ProviderRuntime.reset()
      XtreamCircuitBreaker.reset_all()
    end)
  end

  test "reports authenticated capabilities and dimensioned runtime health" do
    provider = global_provider_fixture(%{password: "secret-that-must-not-escape"})

    capabilities = %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      status: "Active",
      max_connections: 2,
      active_connections: 1,
      allowed_output_formats: ["ts", "m3u8"],
      server_protocol: "https"
    }

    [report] =
      ProviderHealth.list_reports(
        probe_fun: fn ^provider ->
          %{status: :healthy, capabilities: capabilities}
        end
      )

    assert report.id == provider.id
    assert report.status == :healthy
    assert report.dimensions.control.status == :healthy
    assert report.dimensions.live.status == :unknown
    assert report.dimensions.vod.status == :unknown
    assert report.capabilities.max_connections == 2
    assert report.capacity.observed_active_connections == 1
    assert report.capacity.available == 1
    refute inspect(report) =~ "secret-that-must-not-escape"
  end

  test "correlates the circuit breaker by the database provider id" do
    provider = global_provider_fixture()

    for _ <- 1..5 do
      XtreamCircuitBreaker.report_error(provider.id, :server_error)
    end

    # A synchronous call from this process is a mailbox barrier for the casts.
    assert [%{provider_id: provider_id, circuit_state: :open}] =
             XtreamCircuitBreaker.get_all_status()

    assert provider_id == provider.id

    [report] = ProviderHealth.list_reports(probe: false)

    assert report.circuit_state == :open
    assert report.status == :unhealthy
  end

  test "a declared expiry date never degrades an authenticated active account" do
    provider = global_provider_fixture()

    capabilities = %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      status: "Active",
      expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
      max_connections: 1,
      active_connections: 1
    }

    [report] =
      ProviderHealth.list_reports(
        probe_fun: fn ^provider ->
          %{status: ProviderCapabilities.status(capabilities), capabilities: capabilities}
        end
      )

    assert report.status == :healthy
    assert report.dimensions.control.status == :healthy
    assert report.capabilities.expires_at
  end
end
