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

  test "statuses/1 classifies loaded providers like the report without probing upstream" do
    open_circuit = global_provider_fixture()
    probed = global_provider_fixture()
    unprobed = global_provider_fixture()

    inactive =
      global_provider_fixture()
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

    for _ <- 1..5 do
      XtreamCircuitBreaker.report_error(open_circuit.id, :server_error)
    end

    probe_key = {:provider_probe, probed.id}
    ConCache.put(:streamix_l1_cache, probe_key, %{status: :degraded, capabilities: nil})
    on_exit(fn -> ConCache.delete(:streamix_l1_cache, probe_key) end)

    statuses = ProviderHealth.statuses([open_circuit, probed, unprobed, inactive])

    # A cache miss means "no evidence": probing the unreachable example.com
    # host would have classified `unprobed` as unhealthy instead.
    assert statuses == %{
             open_circuit.id => :unhealthy,
             probed.id => :degraded,
             unprobed.id => :unknown,
             inactive.id => :unhealthy
           }

    reported = Map.new(ProviderHealth.list_reports(probe: false), &{&1.id, &1.status})

    assert Map.take(reported, [open_circuit.id, unprobed.id]) ==
             Map.take(statuses, [open_circuit.id, unprobed.id])
  end

  test "a provider its health monitor degraded reports unhealthy while still active" do
    provider = global_provider_fixture(%{name: "Embedplay", provider_type: :embedplay})
    {:ok, _provider} = Streamix.Providers.mark_embedplay_degraded(:no_source_available)

    [report] = ProviderHealth.list_reports(probe: false)

    assert report.id == provider.id
    assert report.is_active
    assert report.status == :unhealthy
    assert report.message == "Provedor temporariamente indisponível. Tentando reconectar."
  end
end
