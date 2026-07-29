defmodule Streamix.QoeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Qoe
  alias Streamix.Qoe.Event
  alias Streamix.Repo

  test "bounds client values and drops fields outside the persistence contract" do
    metric = %{
      "kind" => "playback",
      "engine" => "totally-unknown-engine",
      "content_type" => "movie",
      "ttff_ms" => -10,
      "buffer_count" => 50_000,
      "event" => String.duplicate("x", 100),
      "url" => "https://provider.invalid/credentials"
    }

    assert {:ok, %{accepted: 1}} = Qoe.ingest(nil, "privacy-batch", [metric])

    event = Repo.one!(Event)
    assert event.engine == "unknown"
    assert event.ttff_ms == 0
    assert event.buffer_count == 10_000
    assert event.event == "unknown"
    refute event.batch_id =~ "privacy-batch"
    refute Map.has_key?(Map.from_struct(event), :url)
  end

  test "normalizes legacy client enums without retaining arbitrary labels" do
    assert {:ok, %{accepted: 1}} =
             Qoe.ingest(nil, Ecto.UUID.generate(), [
               %{
                 "engine" => "HLS.js",
                 "stream_type" => "Movie",
                 "event" => "user@example.com"
               }
             ])

    assert %Event{
             engine: "hls",
             content_type: "movie",
             stream_type: "unknown",
             event: "unknown"
           } = Repo.one!(Event)
  end

  test "aggregates recent QoE and purges only rows before the cutoff" do
    assert {:ok, %{accepted: 2}} =
             Qoe.ingest(nil, "summary-batch", [
               %{"kind" => "playback", "ttff_ms" => 500, "buffer_count" => 2},
               %{"kind" => "pwa", "event" => "install_prompt"}
             ])

    assert %{
             event_count: 2,
             playback_sessions: 1,
             pwa_events: 1,
             avg_ttff_ms: 500,
             buffer_count: 2
           } = Qoe.summary()

    assert {0, nil} = Qoe.purge_before(DateTime.add(DateTime.utc_now(), -60, :second))
    assert {2, nil} = Qoe.purge_before(DateTime.add(DateTime.utc_now(), 60, :second))
  end
end
