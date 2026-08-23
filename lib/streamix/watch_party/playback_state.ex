defmodule Streamix.WatchParty.PlaybackState do
  @moduledoc """
  Pure state transitions for a Watch Party playback timeline.

  The room process serializes commands and persistence. This module owns only
  validation and timeline math, which keeps malformed browser payloads away
  from GenServer state and makes play/pause/seek/buffering transitions directly
  testable without starting a room process.
  """

  @max_position_seconds 31_536_000

  @type state :: :playing | :paused
  @type t :: %{
          state: state(),
          position: float(),
          host_buffering: boolean(),
          updated_at: integer()
        }

  @doc "Restores a persisted playback snapshot into the monotonic clock domain."
  @spec restore(map(), keyword()) :: t()
  def restore(snapshot, opts \\ []) do
    monotonic_now = Keyword.get_lazy(opts, :now, &now/0)
    wall_now = Keyword.get_lazy(opts, :wall_now, &DateTime.utc_now/0)

    playback_state =
      if Map.get(snapshot, :playback_state) == "playing", do: :playing, else: :paused

    buffering = Map.get(snapshot, :playback_buffering) == true
    position = finite_position(Map.get(snapshot, :playback_position))

    elapsed =
      if playback_state == :playing and not buffering do
        wall_elapsed(wall_now, Map.get(snapshot, :playback_updated_at))
      else
        0.0
      end

    %{
      state: playback_state,
      position: advance(position, elapsed),
      host_buffering: buffering,
      updated_at: monotonic_now
    }
  end

  @doc "Returns the current extrapolated timeline without mutating the snapshot."
  @spec current(t(), integer()) :: t()
  def current(playback, monotonic_now \\ now())

  def current(%{state: :playing, host_buffering: false} = playback, monotonic_now) do
    elapsed = monotonic_elapsed(monotonic_now, playback.updated_at)
    %{playback | position: advance(finite_position(playback.position), elapsed)}
  end

  def current(playback, _monotonic_now), do: playback

  @doc "Builds a paused timeline at a validated position."
  @spec paused(number(), integer()) :: t()
  def paused(position, monotonic_now \\ now()) do
    %{
      state: :paused,
      position: finite_position(position),
      host_buffering: false,
      updated_at: monotonic_now
    }
  end

  @doc "Applies one validated host transport command."
  @spec apply(t(), map(), integer()) :: {:ok, t()} | {:error, :invalid_playback_action}
  def apply(playback, action, monotonic_now \\ now())

  def apply(_playback, %{"action" => "play", "position" => position}, monotonic_now) do
    with {:ok, position} <- normalize_position(position) do
      {:ok,
       %{
         state: :playing,
         position: position,
         host_buffering: false,
         updated_at: monotonic_now
       }}
    end
  end

  def apply(_playback, %{"action" => "pause", "position" => position}, monotonic_now) do
    with {:ok, position} <- normalize_position(position) do
      {:ok, paused(position, monotonic_now)}
    end
  end

  def apply(playback, %{"action" => "seek", "position" => position}, monotonic_now) do
    with {:ok, position} <- normalize_position(position) do
      current = current(playback, monotonic_now)

      {:ok,
       %{
         current
         | position: position,
           updated_at: monotonic_now,
           host_buffering: false
       }}
    end
  end

  def apply(_playback, _action, _monotonic_now), do: {:error, :invalid_playback_action}

  @doc "Builds the host-authoritative snapshot represented by a beacon."
  @spec from_beacon(number(), String.t(), boolean(), integer()) :: t()
  def from_beacon(position, participant_state, buffering, monotonic_now \\ now()) do
    %{
      state: if(participant_state == "playing", do: :playing, else: :paused),
      position: finite_position(position),
      host_buffering: buffering == true,
      updated_at: monotonic_now
    }
  end

  @doc "Validates the complete browser beacon boundary."
  @spec valid_beacon?(term(), term(), term()) :: boolean()
  def valid_beacon?(position, participant_state, buffering) do
    match?({:ok, _position}, normalize_position(position)) and
      participant_state in ~w(playing paused) and is_boolean(buffering)
  end

  @doc "Normalizes a finite, bounded timeline position."
  @spec normalize_position(term()) :: {:ok, float()} | {:error, :invalid_playback_action}
  def normalize_position(value)
      when is_integer(value) and value >= 0 and value <= @max_position_seconds,
      do: {:ok, value * 1.0}

  def normalize_position(value)
      when is_float(value) and value >= 0 and value <= @max_position_seconds,
      do: {:ok, value}

  def normalize_position(_value), do: {:error, :invalid_playback_action}

  @doc "Returns a safe position for persisted or legacy data."
  @spec finite_position(term()) :: float()
  def finite_position(value) do
    case normalize_position(value) do
      {:ok, position} -> position
      {:error, _reason} -> 0.0
    end
  end

  defp wall_elapsed(%DateTime{} = wall_now, %DateTime{} = updated_at) do
    max(0, DateTime.diff(wall_now, updated_at, :millisecond)) / 1_000.0
  end

  defp wall_elapsed(_wall_now, _updated_at), do: 0.0

  defp monotonic_elapsed(monotonic_now, updated_at)
       when is_integer(monotonic_now) and is_integer(updated_at) do
    max(0, monotonic_now - updated_at) / 1_000.0
  end

  defp monotonic_elapsed(_monotonic_now, _updated_at), do: 0.0

  defp advance(position, elapsed) do
    min(position + max(elapsed, 0.0), @max_position_seconds * 1.0)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
