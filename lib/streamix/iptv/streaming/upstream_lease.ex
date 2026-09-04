defmodule Streamix.Iptv.Streaming.UpstreamLease do
  @moduledoc """
  Acquires a `ProviderRuntime` lease, reclaiming an idle live multiplexer
  first when the provider is at capacity.

  Live multiplexers keep their upstream connection open for a grace period
  after the last viewer leaves, so a channel change, a pause or a reconnect
  does not cost a fresh provider connection. On a provider with a handful of
  slots that grace would otherwise block the next distinct channel, so the
  last slot is taken back from an idle multiplexer instead of answering 503.
  """

  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.StreamMultiplexerSupervisor

  @spec acquire(integer() | nil, :live | :vod, pid()) ::
          {:ok, ProviderRuntime.lease() | :untracked} | {:error, :capacity_exhausted}
  def acquire(provider_id, traffic_class, owner \\ self()) do
    case ProviderRuntime.acquire(provider_id, traffic_class, owner) do
      {:error, :capacity_exhausted} ->
        case StreamMultiplexerSupervisor.reclaim_idle(provider_id, except: owner) do
          :reclaimed -> ProviderRuntime.acquire(provider_id, traffic_class, owner)
          :none -> {:error, :capacity_exhausted}
        end

      result ->
        result
    end
  end
end
