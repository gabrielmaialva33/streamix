defmodule StreamixWeb.PlayerLifecycleTelemetryTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.PlayerLifecycleTelemetry

  test "normalizes the bounded browser lifecycle vocabulary" do
    assert %{
             stage: "player_state_changed",
             engine: "mpegts",
             stream_type: "xtream",
             content_type: "live_channel",
             source_type: "provider",
             session_id: 42,
             from_state: "loading",
             to_state: "playing",
             state_revision: 3,
             state_reason: "media_playing",
             url_present: false
           } =
             PlayerLifecycleTelemetry.normalize(%{
               "stage" => "player_state_changed",
               "engine" => "MPEGTS",
               "current_stream_type" => "xtream",
               "content_type" => "live_channel",
               "source_type" => "provider",
               "session_id" => "42",
               "from_state" => "loading",
               "to_state" => "playing",
               "state_revision" => 3,
               "state_reason" => "media_playing"
             })
  end

  test "accepts atom keys and the legacy stream_type field" do
    assert %{
             engine: "hls",
             stream_type: "hls",
             session_id: 0,
             from_state: "ready",
             to_state: "recovering"
           } =
             PlayerLifecycleTelemetry.normalize(%{
               stage: "player_state_changed",
               engine: "hls",
               stream_type: "hls",
               session_id: 0,
               from_state: "ready",
               to_state: "recovering"
             })
  end

  test "does not retain stream URLs or credentials" do
    normalized =
      PlayerLifecycleTelemetry.normalize(%{
        "stage" => "player_state_changed",
        "stream_url" => "https://user:password@example.test/live.ts",
        "proxy_url" => "https://proxy.test/secret-token",
        "current_url" => "https://origin.test/private.m3u8"
      })

    assert normalized.url_present
    refute Map.has_key?(normalized, :stream_url)
    refute Map.has_key?(normalized, :proxy_url)
    refute Map.has_key?(normalized, :current_url)
    refute inspect(normalized) =~ "password"
    refute inspect(normalized) =~ "secret-token"
  end

  test "bounds diagnostic text and collapses unknown metric labels" do
    normalized =
      PlayerLifecycleTelemetry.normalize(%{
        "stage" => String.duplicate("s", 200),
        "engine" => "custom-engine-per-user",
        "from_state" => "invented-from-state",
        "to_state" => "invented-to-state",
        "state_reason" => "retry\nwith\tcontrol" <> String.duplicate("x", 300),
        "content_type" => "  movie\n ",
        "session_id" => "invalid",
        "state_revision" => -1
      })

    assert String.length(normalized.stage) == 80
    assert normalized.engine == "unknown"
    assert normalized.from_state == "unknown"
    assert normalized.to_state == "unknown"
    assert normalized.content_type == "movie"
    assert normalized.session_id == nil
    assert normalized.state_revision == nil
    assert String.length(normalized.state_reason) == 160
    refute normalized.state_reason =~ "\n"
    refute normalized.state_reason =~ "\t"
  end

  test "emits a bounded metric for accepted state transitions" do
    attach([:streamix, :player, :state_transition])

    assert :ok =
             PlayerLifecycleTelemetry.observe(%{
               "stage" => "player_state_changed",
               "engine" => "avplayer",
               "from_state" => "loading",
               "to_state" => "playing",
               "stream_url" => "https://example.test/private"
             })

    assert_receive {:telemetry, [:streamix, :player, :state_transition], %{count: 1},
                    %{engine: "avplayer", from_state: "loading", to_state: "playing"}}
  end

  test "emits a separate metric for rejected state transitions" do
    attach([:streamix, :player, :state_transition_invalid])

    assert :ok =
             PlayerLifecycleTelemetry.observe(%{
               "stage" => "player_state_transition_invalid",
               "engine" => "unexpected",
               "from_state" => "idle",
               "to_state" => "playing"
             })

    assert_receive {:telemetry, [:streamix, :player, :state_transition_invalid], %{count: 1},
                    %{engine: "unknown", from_state: "idle", to_state: "playing"}}
  end

  test "does not emit state metrics for unrelated lifecycle events" do
    attach([:streamix, :player, :state_transition])
    attach([:streamix, :player, :state_transition_invalid])

    assert :ok =
             PlayerLifecycleTelemetry.observe(%{
               "stage" => "player_engine_selected",
               "engine" => "native"
             })

    refute_receive {:telemetry, _, _, _}
  end

  test "malformed payloads remain a no-op" do
    assert :ok = PlayerLifecycleTelemetry.observe(nil)
    assert :ok = PlayerLifecycleTelemetry.observe("invalid")
    assert :ok = PlayerLifecycleTelemetry.observe([])
  end

  defp attach(event_name) do
    handler_id = {__MODULE__, event_name, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
