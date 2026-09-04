defmodule Streamix.Iptv.Streaming.CapacityTelemetry do
  @moduledoc """
  Makes a refused stream visible to the operator.

  Running out of upstream capacity is the platform's most common failure: the
  provider account sustains only a couple of concurrent connections, so the
  next viewer gets a `503`. Four different causes collapse into that one
  response, and none of them used to leave a trace beyond a Phoenix access log
  line on a signed-token URL, which carries no discriminator at all.

  Every refusal now emits `[:streamix, :stream_proxy, :capacity_exhausted]`.
  This module turns that into a warning line naming the cause, and keeps a
  per-dimension counter so `summary/0` answers "did we refuse anyone, and why"
  from IEx without a metrics stack.
  """

  require Logger

  @table :streamix_capacity_refusals
  @event [:streamix, :stream_proxy, :capacity_exhausted]
  @dimensions [:live, :vod, :gindex_quota, :gindex_rate_limited, :unknown]

  @doc """
  Emits a capacity refusal.

  `dimension` names the cause; the remaining fields are best-effort context.
  Measurements mirror what `VodProxy.Observability` produces so one metric
  definition covers every path.
  """
  @spec refused(atom(), keyword()) :: :ok
  def refused(dimension, metadata \\ []) when is_atom(dimension) do
    :telemetry.execute(
      @event,
      %{bytes_sent: 0, retry_count: 0, duration_ms: 0},
      metadata
      |> Keyword.put_new(:provider_id, nil)
      |> Keyword.put_new(:content_id, nil)
      |> Keyword.put_new(:media_type, nil)
      |> Keyword.put(:dimension, dimension)
      |> Map.new()
    )
  end

  @doc """
  Creates the counter table and attaches the handler.

  Called from `Streamix.RuntimeBootstrap`.
  """
  @spec setup() :: :ok
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      for dimension <- @dimensions, do: :ets.insert(@table, {dimension, 0})
    end

    :telemetry.detach("streamix-capacity-telemetry")

    :telemetry.attach(
      "streamix-capacity-telemetry",
      @event,
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_event(@event, _measurements, metadata, _config) do
    dimension = normalize(Map.get(metadata, :dimension))

    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(@table, dimension, {2, 1}, {dimension, 0})
    end

    Logger.warning(
      "[Capacity] refused a stream: cause=#{dimension} " <>
        "provider=#{inspect(Map.get(metadata, :provider_id))} " <>
        "content=#{inspect(Map.get(metadata, :content_id))} " <>
        "media_type=#{inspect(Map.get(metadata, :media_type))}"
    )

    :ok
  end

  @doc """
  Refusals seen since boot, by cause. Empty when the table is not set up.
  """
  @spec summary() :: map()
  def summary do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      @table |> :ets.tab2list() |> Map.new()
    end
  end

  defp normalize(dimension) when dimension in @dimensions, do: dimension
  defp normalize(_dimension), do: :unknown
end
