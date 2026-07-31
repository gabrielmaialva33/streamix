defmodule Streamix.Iptv.Streaming.SourceSelectorTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.ProviderCapabilities
  alias Streamix.Iptv.Streaming.{ProviderRuntime, SourceSelector}

  setup do
    ProviderRuntime.reset()
    on_exit(&ProviderRuntime.reset/0)
  end

  test "a healthy source wins over an explicitly preferred unhealthy source" do
    ProviderRuntime.record_failure(1, :vod, :timeout)
    ProviderRuntime.record_failure(1, :vod, :timeout)
    ProviderRuntime.record_failure(1, :vod, :timeout)
    ProviderRuntime.record_success(2, :vod, 40)

    assert [best | _] =
             SourceSelector.sort(sources(),
               media_type: :vod,
               preferred_provider_id: 1
             )

    assert best.provider_id == 2
  end

  test "connection capacity is respected before user preference" do
    ProviderRuntime.put_capabilities(1, capabilities(1, 1))
    ProviderRuntime.put_capabilities(2, capabilities(1, 0))
    ProviderRuntime.record_success(1, :vod, 20)
    ProviderRuntime.record_success(2, :vod, 50)

    assert [best | _] =
             SourceSelector.sort(sources(),
               media_type: :vod,
               preferred_provider_id: 1
             )

    assert best.provider_id == 2
  end

  test "uses independent live and VOD observations" do
    ProviderRuntime.record_success(1, :live, 30)
    ProviderRuntime.record_failure(1, :vod, :timeout)
    ProviderRuntime.record_failure(2, :live, :timeout)
    ProviderRuntime.record_success(2, :vod, 30)

    assert [live_best | _] = SourceSelector.sort(sources(), media_type: :live)
    assert [vod_best | _] = SourceSelector.sort(sources(), media_type: :vod)

    assert live_best.provider_id == 1
    assert vod_best.provider_id == 2
  end

  test "uses quality as a deterministic cold-start tiebreaker" do
    [basic, premium] = sources()
    premium = %{premium | name: "Example 4K HDR"}

    assert {:ok, selected} = SourceSelector.select([basic, premium], media_type: :vod)
    assert selected.id == premium.id
  end

  defp sources do
    [
      %{id: 11, provider_id: 1, provider: %{name: "A", is_active: true}, name: "Example"},
      %{id: 22, provider_id: 2, provider: %{name: "B", is_active: true}, name: "Example"}
    ]
  end

  defp capabilities(max_connections, active_connections) do
    %ProviderCapabilities{
      authenticated?: true,
      active?: true,
      max_connections: max_connections,
      active_connections: active_connections
    }
  end
end
