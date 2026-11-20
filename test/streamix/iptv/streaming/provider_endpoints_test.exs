defmodule Streamix.Iptv.Streaming.ProviderEndpointsTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.{Provider, XtreamCircuitBreaker}
  alias Streamix.Iptv.Streaming.{ProviderEndpoints, ProviderRuntime}

  setup do
    ProviderRuntime.reset()
    XtreamCircuitBreaker.reset_all()

    on_exit(fn ->
      ProviderRuntime.reset()
      XtreamCircuitBreaker.reset_all()
    end)
  end

  defp provider(bases, id \\ nil) do
    [url | urls] = bases

    %Provider{
      id: id || 2_000_000 + System.unique_integer([:positive]),
      url: url,
      urls: urls,
      username: "user",
      password: "pass",
      provider_type: :xtream,
      is_system: true
    }
  end

  describe "chain/1" do
    test "defaults to url_chain order" do
      provider = provider(["https://a.test", "https://b.test", "https://c.test"])

      assert ProviderEndpoints.chain(provider) == [
               "https://a.test",
               "https://b.test",
               "https://c.test"
             ]

      assert ProviderEndpoints.base_url(provider) == "https://a.test"
    end

    test "base_url/1 falls back to the provider url when the chain is empty" do
      assert ProviderEndpoints.base_url(%Provider{url: "https://a.test", urls: []}) ==
               "https://a.test"

      assert ProviderEndpoints.base_url(%Provider{url: nil, urls: nil}) == nil
    end

    test "a ranking stored for a different base set is ignored" do
      id = 2_000_000 + System.unique_integer([:positive])
      provider = provider(["https://a.test", "https://b.test"], id)

      assert :ok = ProviderEndpoints.report(provider, "https://b.test", :ok)
      assert ProviderEndpoints.base_url(provider) == "https://b.test"

      # Operator edited the alternates: the stale ranking no longer applies.
      edited = provider(["https://a.test", "https://c.test"], id)
      assert ProviderEndpoints.chain(edited) == ["https://a.test", "https://c.test"]
    end
  end

  describe "report/3" do
    test ":down demotes a base to the end" do
      provider = provider(["https://a.test", "https://b.test"])

      assert :ok = ProviderEndpoints.report(provider, "https://a.test", :down)
      assert ProviderEndpoints.chain(provider) == ["https://b.test", "https://a.test"]
    end

    test ":ok promotes a base to the front" do
      provider = provider(["https://a.test", "https://b.test", "https://c.test"])

      assert :ok = ProviderEndpoints.report(provider, "https://c.test", :ok)

      assert ProviderEndpoints.chain(provider) == [
               "https://c.test",
               "https://a.test",
               "https://b.test"
             ]
    end

    test "reports keep the ranking age, so a stale ranking stays due" do
      provider = provider(["https://a.test", "https://b.test"])

      stale_at = System.monotonic_time(:millisecond) - :timer.minutes(10)

      ConCache.put(:streamix_l1_cache, {:provider_endpoints, provider.id}, %ConCache.Item{
        value: {["https://a.test", "https://b.test"], stale_at},
        ttl: :timer.minutes(30)
      })

      assert ProviderEndpoints.refresh_due?(provider)

      # Reorders the ranking but must not re-stamp it.
      assert :ok = ProviderEndpoints.report(provider, "https://b.test", :ok)
      assert ProviderEndpoints.chain(provider) == ["https://b.test", "https://a.test"]
      assert ProviderEndpoints.refresh_due?(provider)

      # A report that changes nothing writes nothing either.
      assert :ok = ProviderEndpoints.report(provider, "https://a.test", :down)
      assert ProviderEndpoints.refresh_due?(provider)
    end

    test "a report without a stored ranking leaves refresh_due? true" do
      provider = provider(["https://a.test", "https://b.test"])

      assert :ok = ProviderEndpoints.report(provider, "https://b.test", :ok)
      assert ProviderEndpoints.chain(provider) == ["https://b.test", "https://a.test"]
      assert ProviderEndpoints.refresh_due?(provider)
    end
  end

  describe "refresh/2" do
    test "ranks successes by latency with failures last and clears refresh_due?" do
      provider = provider(["https://a.test", "https://b.test", "https://c.test"])
      assert ProviderEndpoints.refresh_due?(provider)

      probe = fn base ->
        case base do
          "https://a.test" ->
            :timer.sleep(80)
            {:ok, %{}}

          "https://b.test" ->
            {:error, :nxdomain}

          _ ->
            {:ok, %{}}
        end
      end

      assert :ok = ProviderEndpoints.refresh(provider, probe: probe)

      assert ProviderEndpoints.chain(provider) == [
               "https://c.test",
               "https://a.test",
               "https://b.test"
             ]

      refute ProviderEndpoints.refresh_due?(provider)
    end

    test "the default probe does not record provider runtime or circuit failures" do
      # Closed listener: connections are refused instantly.
      {:ok, listen} = :gen_tcp.listen(0, [:binary])
      {:ok, dead_port} = :inet.port(listen)
      :gen_tcp.close(listen)

      provider = provider(["http://127.0.0.1:#{dead_port}", "http://127.0.0.1:#{dead_port + 1}"])

      assert :ok = ProviderEndpoints.refresh(provider)

      control = ProviderRuntime.snapshot(provider.id).dimensions.control
      assert control.samples == 0
      assert control.failures == 0

      statuses = XtreamCircuitBreaker.get_all_status()

      refute Enum.any?(statuses, fn status ->
               status.provider_id == provider.id and status.error_count > 0
             end)
    end
  end
end
