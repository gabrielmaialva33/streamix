import assert from "node:assert/strict";
import test from "node:test";

import { PlaybackSession } from "../player/playback_session.js";

test("summarizes one playback session without retaining stream URLs", () => {
  let now = 0;
  const session = new PlaybackSession({
    now: () => now,
    batchId: () => "playback-batch",
  });

  session.begin({ contentType: "vod", streamType: "mkv", displayMode: "standalone" });
  session.selectEngine("hls-js");
  now = 1_200;
  session.markPlaying();
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
    engine: "avplayer",
    content_type: "vod",
    stream_type: "mkv",
    display_mode: "standalone",
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
