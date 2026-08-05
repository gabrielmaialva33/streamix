defmodule Streamix.Iptv.Streaming.StreamMultiplexer.Health do
  @moduledoc false

  require Logger

  alias Streamix.Iptv.Channels
  alias Streamix.Iptv.Streaming.ProviderRuntime

  def record_first_success(%{health_recorded?: true} = state), do: state

  def record_first_success(state) do
    latency = System.monotonic_time(:millisecond) - state.started_at
    ProviderRuntime.record_success(state.provider_id, :live, latency)
    maybe_mark_channel_alive(state.content_id)
    %{state | health_recorded?: true}
  end

  def record_failure(state, {:unexpected_status, status}) when status in [404, 410] do
    maybe_mark_channel_dead(state.content_id)
  end

  def record_failure(state, reason) do
    ProviderRuntime.record_failure(state.provider_id, :live, reason)
  end

  defp maybe_mark_channel_alive(content_id) when is_integer(content_id) do
    safe_channel_update(fn -> Channels.mark_alive(content_id) end)
  end

  defp maybe_mark_channel_alive(_content_id), do: :ok

  defp maybe_mark_channel_dead(content_id) when is_integer(content_id) do
    safe_channel_update(fn -> Channels.mark_dead(content_id) end)
  end

  defp maybe_mark_channel_dead(_content_id), do: :ok

  defp safe_channel_update(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[StreamMux] channel liveness update failed: #{Exception.message(error)}")
      :ok
  end
end
