defmodule Streamix.QoeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Qoe
  alias Streamix.Qoe.Event
  alias Streamix.Repo

  test "persists bounded playback reasons and the served client revision, without adding identity" do
    revision = String.duplicate("a", 40)

    assert {:ok, %{accepted: 1}} =
             Qoe.record_client_event(nil, %{
               "batch_id" => Ecto.UUID.generate(),
               "kind" => "playback",
               "event" => "playback_session",
               "outcome" => "error",
               "end_reason" => "startup_deadline",
               "engine_reason" => "provider_memory",
               "client_revision" => revision,
               "provider_id" => 3,
               "title" => "Synthetic",
               "url" => "https://invalid.test/secret"
             })

    event = Repo.one!(Event)
    assert Map.get(event, :end_reason) == "startup_deadline"
    assert Map.get(event, :engine_reason) == "provider_memory"
    assert Map.get(event, :client_revision) == revision
    refute Map.has_key?(event, :provider_id)
    refute Map.has_key?(event, :title)
    refute Map.has_key?(event, :url)
  end

  test "invalid and oversized labels or revisions are discarded, and older clients remain accepted" do
    for metric <- [
          %{},
          %{
            "end_reason" => "https://invalid.test/token",
            "engine_reason" => "person@example.test",
            "client_revision" => "https://invalid.test/token"
          },
          %{
            "end_reason" => "startup_deadline" <> String.duplicate("x", 200),
            "engine_reason" => ["capability"],
            "client_revision" => String.duplicate("a", 41)
          }
        ] do
      batch = Ecto.UUID.generate()
      assert {:ok, %{accepted: 1}} = Qoe.ingest(nil, batch, [metric])
      event = Repo.get_by!(Event, batch_id: batch)
      assert Map.get(event, :end_reason) == nil
      assert Map.get(event, :engine_reason) == nil
      assert Map.get(event, :client_revision) == nil
    end
  end

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

  test "calculates p75 Core Web Vitals SLOs by device class" do
    mobile =
      for index <- 0..19 do
        %{
          "kind" => "web_vital",
          "event" => "page_vitals",
          "device_class" => "mobile",
          "lcp_ms" => 1_000 + index,
          "inp_ms" => 100 + index,
          "cls_milli" => 50 + index
        }
      end

    desktop =
      for _index <- 0..19 do
        %{
          "kind" => "web_vital",
          "event" => "page_vitals",
          "device_class" => "desktop",
          "lcp_ms" => 4_500,
          "inp_ms" => 550,
          "cls_milli" => 300
        }
      end

    assert {:ok, %{accepted: 40}} =
             Qoe.ingest(nil, "device-segment-batch", mobile ++ desktop)

    assert %{
             web_vitals: 40,
             web_vitals_slo: %{
               all: %{sample_count: 40, status: :poor},
               mobile: %{
                 sample_count: 20,
                 status: :good,
                 lcp: %{p75: 1_014, samples: 20, status: :good},
                 inp: %{p75: 114, samples: 20, status: :good},
                 cls: %{p75: 64, samples: 20, status: :good}
               },
               desktop: %{
                 sample_count: 20,
                 status: :poor,
                 lcp: %{p75: 4_500, samples: 20, status: :poor},
                 inp: %{p75: 550, samples: 20, status: :poor},
                 cls: %{p75: 300, samples: 20, status: :poor}
               }
             }
           } = Qoe.summary()
  end
end
