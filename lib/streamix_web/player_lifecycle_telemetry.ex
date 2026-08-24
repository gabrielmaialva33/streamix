defmodule StreamixWeb.PlayerLifecycleTelemetry do
  @moduledoc """
  Normalizes browser playback lifecycle events before logging or telemetry.

  Client payloads are untrusted input. This boundary keeps metric labels within
  fixed vocabularies, bounds diagnostic text, and intentionally drops stream
  URLs so provider credentials cannot reach application logs.
  """

  require Logger

  @known_engines MapSet.new(~w(native hls mpegts avplayer avbridge h265web unknown))

  @known_states MapSet.new(
                  ~w(idle selecting_source loading ready playing stalled recovering terminal destroyed unknown)
                )

  @state_changed_stage "player_state_changed"
  @state_invalid_stage "player_state_transition_invalid"

  @type normalized_event :: %{
          stage: String.t(),
          engine: String.t(),
          stream_type: String.t() | nil,
          content_type: String.t() | nil,
          source_type: String.t() | nil,
          session_id: non_neg_integer() | nil,
          from_state: String.t(),
          to_state: String.t(),
          state_revision: non_neg_integer() | nil,
          state_reason: String.t() | nil,
          url_present: boolean()
        }

  @spec observe(map()) :: :ok
  def observe(params) when is_map(params) do
    event = normalize(params)
    emit_metric(event)
    maybe_log(event)
    :ok
  end

  def observe(_params), do: :ok

  @doc false
  @spec normalize(map()) :: normalized_event()
  def normalize(params) when is_map(params) do
    %{
      stage: bounded_text(value(params, "stage", :stage), 80, "unknown"),
      engine: normalize_enum(value(params, "engine", :engine), @known_engines),
      stream_type:
        bounded_text(
          value(params, "current_stream_type", :current_stream_type) ||
            value(params, "stream_type", :stream_type),
          40
        ),
      content_type: bounded_text(value(params, "content_type", :content_type), 40),
      source_type: bounded_text(value(params, "source_type", :source_type), 40),
      session_id: non_negative_integer(value(params, "session_id", :session_id)),
      from_state: normalize_enum(value(params, "from_state", :from_state), @known_states),
      to_state: normalize_enum(value(params, "to_state", :to_state), @known_states),
      state_revision: non_negative_integer(value(params, "state_revision", :state_revision)),
      state_reason: bounded_text(value(params, "state_reason", :state_reason), 160),
      url_present: url_present?(params)
    }
  end

  defp emit_metric(%{stage: @state_changed_stage} = event) do
    :telemetry.execute(
      [:streamix, :player, :state_transition],
      %{count: 1},
      metric_metadata(event)
    )
  end

  defp emit_metric(%{stage: @state_invalid_stage} = event) do
    :telemetry.execute(
      [:streamix, :player, :state_transition_invalid],
      %{count: 1},
      metric_metadata(event)
    )
  end

  defp emit_metric(_event), do: :ok

  defp metric_metadata(event) do
    Map.take(event, [:from_state, :to_state, :engine])
  end

  defp maybe_log(event) do
    if Application.get_env(:streamix, :player_lifecycle_logs, false) do
      Logger.info("[PlayerLifecycle] client event",
        stage: event.stage,
        engine: event.engine,
        stream_type: event.stream_type,
        content_type: event.content_type,
        source_type: event.source_type,
        session_id: event.session_id,
        from_state: event.from_state,
        to_state: event.to_state,
        state_revision: event.state_revision,
        state_reason: event.state_reason,
        url_present: event.url_present
      )
    end

    :ok
  end

  defp value(params, string_key, atom_key) do
    Map.get(params, string_key) || Map.get(params, atom_key)
  end

  defp normalize_enum(value, allowed) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    if MapSet.member?(allowed, normalized), do: normalized, else: "unknown"
  end

  defp normalize_enum(_value, _allowed), do: "unknown"

  defp bounded_text(value, maximum, default \\ nil)

  defp bounded_text(value, maximum, default) when is_binary(value) do
    normalized =
      value
      |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
      |> String.trim()
      |> String.slice(0, maximum)

    if normalized == "", do: default, else: normalized
  end

  defp bounded_text(_value, _maximum, default), do: default

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp url_present?(params) do
    Enum.any?(
      ["current_url", "stream_url", "proxy_url", :current_url, :stream_url, :proxy_url],
      &(is_binary(Map.get(params, &1)) and Map.get(params, &1) != "")
    )
  end
end
