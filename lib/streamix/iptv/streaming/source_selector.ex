defmodule Streamix.Iptv.Streaming.SourceSelector do
  @moduledoc """
  Ranks equivalent provider sources using live runtime evidence.

  Selection is media-specific: a provider may be healthy for live channels and
  degraded for VOD. Explicit user preference is honored only after hard
  availability, connection capacity and health, so a selected-but-broken
  provider never wins over a working alternative.
  """

  alias Streamix.Iptv.Streaming.ProviderRuntime

  @status_rank %{healthy: 0, unknown: 1, degraded: 2, unhealthy: 3}

  @doc "Sorts sources from best to worst for the requested media type."
  @spec sort([map()], keyword()) :: [map()]
  def sort(sources, opts \\ []) when is_list(sources) do
    dimension = dimension(Keyword.get(opts, :media_type, :vod))
    preferred_provider_id = Keyword.get(opts, :preferred_provider_id)
    current_source_id = Keyword.get(opts, :current_source_id)

    Enum.sort_by(sources, fn source ->
      rank(source, dimension, preferred_provider_id, current_source_id)
    end)
  end

  @doc "Returns the highest-ranked source, if one exists."
  @spec select([map()], keyword()) :: {:ok, map()} | {:error, :no_sources}
  def select(sources, opts \\ []) do
    case sort(sources, opts) do
      [source | _] -> {:ok, source}
      [] -> {:error, :no_sources}
    end
  end

  defp rank(source, dimension, preferred_provider_id, current_source_id) do
    provider_id = Map.get(source, :provider_id)
    runtime = runtime_snapshot(provider_id)
    status = effective_status(runtime.dimensions, dimension)
    capacity = runtime.capacity

    {
      hard_unavailable_rank(source, runtime.capabilities, status),
      capacity_rank(capacity),
      Map.fetch!(@status_rank, status),
      preferred_rank(provider_id, preferred_provider_id),
      latency_rank(runtime.dimensions, dimension),
      -quality_score(source),
      -capacity.available,
      current_rank(Map.get(source, :id), current_source_id),
      provider_name(source),
      Map.get(source, :id, 0)
    }
  end

  defp runtime_snapshot(provider_id) when is_integer(provider_id),
    do: ProviderRuntime.snapshot(provider_id)

  defp runtime_snapshot(_provider_id) do
    %{
      capabilities: nil,
      capacity: %{
        available: 1,
        max_connections: 1,
        observed_active_connections: 0,
        leased_connections: 0
      },
      dimensions: %{
        control: %{status: :unknown, ewma_latency_ms: nil},
        live: %{status: :unknown, ewma_latency_ms: nil},
        vod: %{status: :unknown, ewma_latency_ms: nil}
      }
    }
  end

  defp effective_status(dimensions, dimension) do
    case get_in(dimensions, [dimension, :status]) do
      :unknown -> get_in(dimensions, [:control, :status]) || :unknown
      status when status in ~w(healthy degraded unhealthy)a -> status
      _ -> :unknown
    end
  end

  defp hard_unavailable_rank(source, capabilities, status) do
    provider_active? =
      case Map.get(source, :provider) do
        %{is_active: false} -> false
        _ -> true
      end

    account_active? = is_nil(capabilities) or Map.get(capabilities, :active, true)

    if provider_active? and account_active? and status != :unhealthy, do: 0, else: 1
  end

  defp capacity_rank(%{available: available}) when available > 0, do: 0
  defp capacity_rank(_capacity), do: 1

  defp preferred_rank(provider_id, provider_id) when not is_nil(provider_id), do: 0
  defp preferred_rank(_provider_id, _preferred_provider_id), do: 1

  defp current_rank(source_id, source_id) when not is_nil(source_id), do: 0
  defp current_rank(_source_id, _current_source_id), do: 1

  defp latency_rank(dimensions, dimension) do
    get_in(dimensions, [dimension, :ewma_latency_ms]) ||
      get_in(dimensions, [:control, :ewma_latency_ms]) || 1_000_000_000
  end

  defp quality_score(source) do
    label = String.downcase("#{Map.get(source, :name)} #{Map.get(source, :title)}")

    [
      {String.contains?(label, "4k"), 40},
      {String.contains?(label, "2160p"), 35},
      {String.contains?(label, "hdr"), 20},
      {String.contains?(label, "1080p"), 10},
      {present?(Map.get(source, :duration_secs)), 3},
      {present?(Map.get(source, :tmdb_id)), 2}
    ]
    |> Enum.reduce(0, fn
      {true, points}, score -> score + points
      {false, _points}, score -> score
    end)
  end

  defp present?(value), do: value not in [nil, "", 0]

  defp provider_name(%{provider: %{name: name}}) when is_binary(name), do: name

  defp provider_name(%{provider_id: provider_id}) when is_integer(provider_id),
    do: Integer.to_string(provider_id)

  defp provider_name(_source), do: ""

  defp dimension(value) when value in [:channel, :live, "channel", "live"], do: :live
  defp dimension(_value), do: :vod
end
