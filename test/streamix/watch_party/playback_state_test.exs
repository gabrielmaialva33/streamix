defmodule Streamix.WatchParty.PlaybackStateTest do
  use ExUnit.Case, async: true

  alias Streamix.WatchParty.PlaybackState

  test "applies play, pause, and seek against one monotonic timeline" do
    paused = PlaybackState.paused(10, 1_000)

    assert {:ok, playing} =
             PlaybackState.apply(paused, %{"action" => "play", "position" => 10}, 2_000)

    assert %{state: :playing, host_buffering: false, position: 12.5} =
             PlaybackState.current(playing, 4_500)

    assert {:ok, sought} =
             PlaybackState.apply(playing, %{"action" => "seek", "position" => 30}, 5_000)

    assert %{state: :playing, position: 30.0, updated_at: 5_000} = sought

    assert {:ok, paused_again} =
             PlaybackState.apply(sought, %{"action" => "pause", "position" => 31.5}, 5_500)

    assert %{state: :paused, position: 31.5, host_buffering: false} = paused_again
  end

  test "buffering freezes extrapolation until the host sends a new beacon" do
    buffering = PlaybackState.from_beacon(25.0, "playing", true, 1_000)
    assert PlaybackState.current(buffering, 9_000).position == 25.0

    resumed = PlaybackState.from_beacon(25.0, "playing", false, 9_000)
    assert_in_delta PlaybackState.current(resumed, 11_500).position, 27.5, 0.001
  end

  test "rejects malformed and unbounded browser positions" do
    playback = PlaybackState.paused(0, 0)

    for invalid <- [-1, "12", :nan, 31_536_001] do
      assert {:error, :invalid_playback_action} =
               PlaybackState.apply(playback, %{"action" => "play", "position" => invalid}, 10)
    end

    refute PlaybackState.valid_beacon?("12", "playing", false)
    refute PlaybackState.valid_beacon?(12, "invalid", false)
    refute PlaybackState.valid_beacon?(12, "playing", "false")
    assert PlaybackState.valid_beacon?(12.5, "paused", true)
  end

  test "restores a running persisted snapshot with bounded wall-clock elapsed time" do
    updated_at = ~U[2026-01-01 12:00:00Z]

    restored =
      PlaybackState.restore(
        %{
          playback_state: "playing",
          playback_position: 40.0,
          playback_buffering: false,
          playback_updated_at: updated_at
        },
        now: 5_000,
        wall_now: ~U[2026-01-01 12:00:03Z]
      )

    assert %{state: :playing, position: 43.0, updated_at: 5_000} = restored

    buffered =
      PlaybackState.restore(
        %{
          playback_state: "playing",
          playback_position: "invalid",
          playback_buffering: true,
          playback_updated_at: updated_at
        },
        now: 6_000,
        wall_now: ~U[2026-01-01 12:10:00Z]
      )

    assert %{host_buffering: true, updated_at: 6_000} = buffered
    assert buffered.position == 0.0
  end
end
