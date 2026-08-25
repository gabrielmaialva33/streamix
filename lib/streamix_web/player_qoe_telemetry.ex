defmodule StreamixWeb.PlayerQoeTelemetry do
  @moduledoc """
  Normalizes bounded Quality of Experience measurements from the browser.

  QoE payloads intentionally exclude URLs, content names and user identifiers.
  Only fixed labels and numeric session measurements reach `:telemetry`.
  """

  @known_engines MapSet.new(~w(native hls mpegts avplayer avbridge h265web unknown))

  @known_events MapSet.new(
                  ~w(begin engine metadata ready playing stall_start stall_end recovery fallback error fatal_error finish)
                )

  @numeric_fields [
    :startup_ms,
    :metadata_ms,
    :ready_ms,
    :wall_duration_ms,
    :rebuffer_count,
    :rebuffer_duration_ms,
    :rebuffer_ratio,
    :fallback_count,
    :recovery_count,
    :error_count,
    :fatal_error_count,
    :engine_changes,
    :current_time,
    :duration,
    :live_latency,
    :bandwidth_estimate,
    :dropped_frames,
    :decoded_frames,
    :frame_drop_ratio
  ]

  @spec observe(map()) :: :ok
  def observe(params) when is_map(params) do
    if value(params, "stage", :stage) == "player_qoe" do
      normalized = normalize(params)

      :telemetry.execute(
        [:streamix, :player, :qoe],
        Map.put(normalized.measurements, :count, 1),
        normalized.metadata
      )
    end

    :ok
  end

  def observe(_params), do: :ok

  @doc false
  @spec normalize(map()) :: %{measurements: map(), metadata: map()}
  def normalize(params) when is_map(params) do
    measurements =
      Map.new(@numeric_fields, fn field ->
        {field, non_negative_number(value(params, Atom.to_string(field), field))}
      end)

    %{
      measurements: measurements,
      metadata: %{
        qoe_event: normalize_enum(value(params, "qoe_event", :qoe_event), @known_events),
        engine: normalize_enum(value(params, "engine", :engine), @known_engines),
        live: boolean(value(params, "live", :live)),
        reason: bounded_reason(value(params, "qoe_reason", :qoe_reason))
      }
    }
  end

  defp value(params, string_key, atom_key) do
    case Map.fetch(params, string_key) do
      {:ok, value} -> value
      :error -> Map.get(params, atom_key)
    end
  end

  defp normalize_enum(value, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if MapSet.member?(allowed, normalized), do: normalized, else: "unknown"
  end

  defp normalize_enum(_value, _allowed), do: "unknown"

  defp non_negative_number(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_number(value) when is_float(value) and value >= 0, do: value

  defp non_negative_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> number
      _other -> 0
    end
  end

  defp non_negative_number(_value), do: 0

  defp boolean(true), do: true
  defp boolean("true"), do: true
  defp boolean(1), do: true
  defp boolean(_value), do: false

  defp bounded_reason(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp bounded_reason(_value), do: nil
end
