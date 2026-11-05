import assert from "node:assert/strict";
import test from "node:test";

import { PlaybackSession } from "../player/playback_session.js";

test("summarizes one playback session without retaining stream URLs", () => {
  let now = 0;
  const session = new PlaybackSession({
    now: () => now,
    batchId: () => "playback-batch",
  });

  session.begin({
    contentType: "vod",
    streamType: "mkv",
    displayMode: "standalone",
  });
  session.selectEngine("hls-js");
  now = 1_200;
  session.markFirstFrame();
  now = 2_000;
  session.setBuffering(true);
  session.setBuffering(true);
  now = 2_450;
  session.setBuffering(false);
  session.recordError();
  session.recordFallback("avplayer");
  session.markMutedMismatch();
  now = 5_000;

  assert.deepEqual(session.finish("completed"), {
    batch_id: "playback-batch",
    kind: "playback",
    event: "playback_session",
    outcome: "completed",
    end_reason: "completed",
    engine_reason: "unknown",
    client_revision: undefined,
    engine: "avplayer",
    content_type: "vod",
    stream_type: "mkv",
    display_mode: "standalone",
    device_class: "unknown",
    ttff_ms: 1_200,
    buffer_count: 1,
    buffer_duration_ms: 450,
    session_duration_ms: 5_000,
    error_count: 1,
    fallback_count: 1,
    muted_mismatch: true,
  });

  assert.equal(session.finish("completed"), null);
});

test("deduplicates fallback reports that target the selected engine", () => {
  const session = new PlaybackSession({ batchId: () => "batch-2" });
  session.begin();
  session.selectEngine("native");
  session.recordFallback("avplayer");
  session.recordFallback("avplayer");

  assert.equal(session.finish("error").fallback_count, 1);
});

test("TTFF waits for presented frame, preserves origin across startup marks and excludes startup buffer count", () => {
  let now = 200;
  const session = new PlaybackSession({
    now: () => now,
    batchId: () => "timed",
  });
  session.begin({ startedAt: 0 });
  session.markStage("url");
  session.setBuffering(true);
  now = 500;
  session.markPlaying();
  assert.equal(session.active.playingAt, null);
  now = 900;
  session.markStage("metadata");
  now = 1000;
  session.markFirstFrame();
  now = 2000;
  session.setBuffering(true);
  now = 2300;
  session.markPlaying();
  assert.deepEqual(session.active.marks, {
    url: 200,
    metadata: 900,
    frame: 1000,
  });
  const payload = session.finish();
  assert.equal(payload.ttff_ms, 1000);
  assert.equal(payload.buffer_count, 1);
  assert.equal(payload.buffer_duration_ms, 300);
  assert.equal("marks" in payload, false);
});

test("startup waits without a first frame never count as rebuffer duration", () => {
  let now = 0;
  const session = new PlaybackSession({ now: () => now });
  session.begin();
  session.setBuffering(true);
  now = 30000;
  const payload = session.finish("error");
  assert.equal(payload.buffer_count, 0);
  assert.equal(payload.buffer_duration_ms, 0);
  assert.equal(payload.ttff_ms, undefined);
});

test("session records bounded engine/end reasons and the served build rather than error text", () => {
  const session = new PlaybackSession({ now: () => 30000 });
  session.begin({ clientRevision: "a".repeat(40) });
  session.selectEngine("avplayer", "provider_memory");
  const sample = session.finish("error", "startup_deadline");
  assert.equal(sample.end_reason, "startup_deadline");
  assert.equal(sample.engine_reason, "provider_memory");
  assert.equal(sample.client_revision, "a".repeat(40));

  session.begin({ clientRevision: "https://invalid.test/secret" });
  session.selectEngine("native", "person@example.test");
  assert.equal(session.finish("error", "https://invalid.test/secret").end_reason, "unknown");
  session.begin();
  session.markFirstFrame();
  const left = session.finish("cancelled");
  assert.equal(left.end_reason, "first_frame_then_user_left");
  assert.equal(left.client_revision, undefined);
});

test("a playback session reports the device class it began on", () => {
  let clock = 0;
  const session = new PlaybackSession({ now: () => clock, batchId: () => "batch" });

  session.begin({ deviceClass: "mobile" });
  clock = 10;
  assert.equal(session.finish("completed").device_class, "mobile");

  session.begin({ deviceClass: "tablet-ish" });
  assert.equal(session.finish("cancelled").device_class, "unknown");
});
