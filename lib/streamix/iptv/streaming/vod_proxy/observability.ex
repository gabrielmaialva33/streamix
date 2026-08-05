defmodule Streamix.Iptv.Streaming.VodProxy.Observability do
  @moduledoc false

  require Logger

  alias Streamix.Iptv.Channels
  alias Streamix.Iptv.Streaming.ProviderRuntime

  @spec context(keyword()) :: map()
  def context(opts) do
    media_type = opts |> Keyword.get(:media_type) |> normalize_media_type()

    %{
      provider_id: Keyword.get(opts, :provider_id),
      content_id: Keyword.get(opts, :content_id),
      media_type: media_type,
      dimension: if(media_type == "channel", do: :live, else: :vod),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @spec context_from_conn(Plug.Conn.t()) :: map()
  def context_from_conn(conn) do
    Map.get(conn.private, :streamix_proxy_context) || context([])
  end

  @spec record_success(map()) :: :ok
  def record_success(%{provider_id: provider_id, dimension: dimension} = state)
      when is_integer(provider_id) do
    latency_ms = System.monotonic_time(:millisecond) - state.started_at
    ProviderRuntime.record_success(provider_id, dimension, latency_ms)
    maybe_mark_channel_alive(state)
  end

  def record_success(_state), do: :ok

  @spec record_failure(map(), term()) :: :ok
  def record_failure(%{provider_id: provider_id, dimension: dimension} = state, reason)
      when is_integer(provider_id) do
    if content_missing?(reason) do
      maybe_mark_channel_dead(state)
    else
      ProviderRuntime.record_failure(provider_id, dimension, reason)
    end
  end

  def record_failure(_state, _reason), do: :ok

  @spec emit(atom(), map(), keyword()) :: :ok
  def emit(event, state, metadata \\ []) do
    metadata =
      metadata
      |> Keyword.put(:retry_count, state.retry_count)
      |> Keyword.put(:duration_ms, System.monotonic_time(:millisecond) - state.started_at)
      |> maybe_put_metadata(:provider_id, Map.get(state, :provider_id))
      |> maybe_put_metadata(:content_id, Map.get(state, :content_id))
      |> maybe_put_metadata(:media_type, Map.get(state, :media_type))

    measurements = %{
      bytes_sent: Keyword.get(metadata, :bytes_sent, state.bytes_sent),
      retry_count: state.retry_count,
      duration_ms: Keyword.fetch!(metadata, :duration_ms)
    }

    metadata =
      metadata
      |> Keyword.delete(:bytes_sent)
      |> Keyword.delete(:duration_ms)
      |> Map.new()

    :telemetry.execute([:streamix, :stream_proxy, event], measurements, metadata)
  end

  defp content_missing?({:unexpected_status, status}) when status in [404, 410], do: true
  defp content_missing?(_reason), do: false

  defp maybe_mark_channel_alive(%{media_type: "channel", content_id: content_id})
       when is_integer(content_id) do
    safe_channel_update(fn -> Channels.mark_alive(content_id) end)
  end

  defp maybe_mark_channel_alive(_state), do: :ok

  defp maybe_mark_channel_dead(%{media_type: "channel", content_id: content_id})
       when is_integer(content_id) do
    safe_channel_update(fn -> Channels.mark_dead(content_id) end)
  end

  defp maybe_mark_channel_dead(_state), do: :ok

  defp safe_channel_update(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[VodProxy] channel liveness update failed: #{Exception.message(error)}")
      :ok
  end

  defp normalize_media_type(nil), do: nil
  defp normalize_media_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_media_type(value) when is_binary(value), do: value
  defp normalize_media_type(_value), do: nil

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)
end
