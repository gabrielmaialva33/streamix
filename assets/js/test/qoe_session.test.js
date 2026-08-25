import assert from "node:assert/strict";
import test from "node:test";

import { createQoESession } from "../player/qoe_session.js";

function clock(initial = 0) {
  let value = initial;
  return {
    now: () => value,
    advance: (milliseconds) => {
      value += milliseconds;
    },
  };
}

test("measures startup, stalls and session duration deterministically", () => {
  const time = clock(1_000);
  const session = createQoESession({ now: time.now });

  session.begin({ sessionId: 7, engine: "hls", live: true });
  time.advance(100);
  session.markMetadata();
  time.advance(150);
  session.markReady();
  time.advance(250);
  session.markPlaying();
  time.advance(1_000);
  session.startStall();
  time.advance(300);
  session.markPlaying();
  time.advance(700);
  session.finish("ended");

  const snapshot = session.snapshot();
  assert.equal(snapshot.sessionId, 7);
  assert.equal(snapshot.engine, "hls");
  assert.equal(snapshot.live, true);
  assert.equal(snapshot.metadataMs, 100);
  assert.equal(snapshot.readyMs, 250);
  assert.equal(snapshot.startupMs, 500);
  assert.equal(snapshot.wallDurationMs, 2_500);
  assert.equal(snapshot.rebufferCount, 1);
  assert.equal(snapshot.rebufferDurationMs, 300);
  assert.equal(snapshot.rebufferRatio, 0.15);
  assert.equal(snapshot.finished, true);
});

test("tracks fallback, recovery and bounded errors", () => {
  const time = clock();
  const session = createQoESession({ now: time.now });
  session.begin({ engine: "hls" });

  session.recordRecovery("manifest_retry");
  session.recordFallback({ from: "hls", to: "mpegts", reason: "manifest_failed" });
  session.recordError({ fatal: false, reason: "network" });
  session.recordError({ fatal: true, reason: "decode" });

  const snapshot = session.snapshot();
  assert.equal(snapshot.engine, "mpegts");
  assert.equal(snapshot.recoveryCount, 1);
  assert.equal(snapshot.fallbackCount, 1);
  assert.equal(snapshot.errorCount, 2);
  assert.equal(snapshot.fatalErrorCount, 1);
  assert.equal(snapshot.engineChanges, 1);
  assert.equal(snapshot.lastReason, "decode");
});

test("updates transport diagnostics and frame-drop ratio", () => {
  const session = createQoESession({ now: () => 10 });
  session.begin({ engine: "mpegts" });
  session.updateTransport({
    currentTime: 30,
    duration: 120,
    liveLatency: 3.5,
    bandwidthEstimate: 8_000_000,
    droppedFrames: 5,
    decodedFrames: 500,
  });

  const snapshot = session.snapshot();
  assert.equal(snapshot.currentTime, 30);
  assert.equal(snapshot.duration, 120);
  assert.equal(snapshot.liveLatency, 3.5);
  assert.equal(snapshot.bandwidthEstimate, 8_000_000);
  assert.equal(snapshot.frameDropRatio, 0.01);
});

test("emits immutable snapshots without propagating telemetry failures", () => {
  const events = [];
  const session = createQoESession({
    now: () => 100,
    emit(event, snapshot) {
      events.push([event, snapshot]);
      if (event === "playing") throw new Error("telemetry unavailable");
    },
  });

  session.begin();
  assert.doesNotThrow(() => session.markPlaying());
  assert.equal(events[0][0], "begin");
  assert.equal(events[1][0], "playing");
  assert.equal(Object.isFrozen(events[1][1]), true);
});

test("active stalls are reflected before they finish", () => {
  const time = clock();
  const session = createQoESession({ now: time.now });
  session.begin();
  time.advance(100);
  session.markPlaying();
  time.advance(200);
  session.startStall();
  time.advance(250);

  const snapshot = session.snapshot();
  assert.equal(snapshot.rebufferDurationMs, 250);
  assert.equal(snapshot.rebufferCount, 1);
});

test("finish and duplicate lifecycle events are idempotent", () => {
  const session = createQoESession({ now: () => 1 });
  session.begin();

  assert.equal(session.markMetadata(), true);
  assert.equal(session.markMetadata(), false);
  assert.equal(session.startStall(), true);
  assert.equal(session.startStall(), false);
  assert.equal(session.finish(), true);
  assert.equal(session.finish(), false);
  assert.equal(session.recordRecovery(), false);
});
