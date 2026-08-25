import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_ID, PLAYBACK_STATE } from "../player/engine_contract.js";
import { createPlaybackOrchestrator } from "../player/playback_orchestrator.js";

function engineDouble() {
  return {
    load() {},
    play() {},
    pause() {},
    seek() {},
    destroy() {},
  };
}

test("coordinates session, engine and lifecycle snapshots", () => {
  const lifecycle = [];
  const orchestrator = createPlaybackOrchestrator({
    reportLifecycle: (event, metadata) => lifecycle.push([event, metadata]),
  });

  assert.equal(orchestrator.begin({ content_type: "movie" }), 1);
  orchestrator.activateEngine(ENGINE_ID.NATIVE, engineDouble());
  orchestrator.ready();
  orchestrator.playing();

  const snapshot = orchestrator.snapshot();
  assert.equal(snapshot.sessionId, 1);
  assert.equal(snapshot.engineId, ENGINE_ID.NATIVE);
  assert.equal(snapshot.lifecycle.state, PLAYBACK_STATE.PLAYING);
  assert.equal(snapshot.registry.activeId, ENGINE_ID.NATIVE);
  assert.equal(snapshot.qoe.engine, ENGINE_ID.NATIVE);
  assert.equal(snapshot.qoe.startupMs != null, true);
  assert.equal(
    lifecycle.some(([event]) => event === "player_engine_changed"),
    true,
  );
});

test("creates a fresh observer for every session", () => {
  const orchestrator = createPlaybackOrchestrator();

  orchestrator.begin();
  orchestrator.activateEngine(ENGINE_ID.HLS, engineDouble());
  orchestrator.playing();
  assert.equal(orchestrator.snapshot().lifecycle.state, PLAYBACK_STATE.PLAYING);

  assert.equal(orchestrator.begin(), 2);
  assert.equal(orchestrator.snapshot().lifecycle.state, PLAYBACK_STATE.SELECTING_SOURCE);
  assert.equal(orchestrator.isCurrent(1), false);
  assert.equal(orchestrator.isCurrent(2), true);
});

test("exposes focused lifecycle helpers", () => {
  const orchestrator = createPlaybackOrchestrator();
  orchestrator.begin();
  orchestrator.activateEngine(ENGINE_ID.MPEGTS, engineDouble());

  orchestrator.stalled();
  assert.equal(orchestrator.snapshot().lifecycle.state, PLAYBACK_STATE.STALLED);
  orchestrator.recovering();
  assert.equal(orchestrator.snapshot().lifecycle.state, PLAYBACK_STATE.RECOVERING);
  orchestrator.playing();
  orchestrator.ended();
  assert.equal(orchestrator.snapshot().lifecycle.state, PLAYBACK_STATE.ENDED);
});

test("records fallback, transport and QoE diagnostics", () => {
  const orchestrator = createPlaybackOrchestrator();
  orchestrator.begin({ live: true });
  orchestrator.activateEngine(ENGINE_ID.HLS, engineDouble());
  orchestrator.updateTransport({
    currentTime: 10,
    duration: 100,
    latency: 2.5,
    bandwidthEstimate: 6_000_000,
    droppedFrames: 3,
    decodedFrames: 300,
  });
  orchestrator.recordFallback({
    from: ENGINE_ID.HLS,
    to: ENGINE_ID.MPEGTS,
    reason: "manifest_failed",
  });

  const qoe = orchestrator.snapshot().qoe;
  assert.equal(qoe.live, true);
  assert.equal(qoe.fallbackCount, 1);
  assert.equal(qoe.engine, ENGINE_ID.MPEGTS);
  assert.equal(qoe.liveLatency, 2.5);
  assert.equal(qoe.frameDropRatio, 0.01);
});

test("destroy is idempotent and terminal", () => {
  const orchestrator = createPlaybackOrchestrator();
  orchestrator.begin();
  orchestrator.activateEngine(ENGINE_ID.NATIVE, engineDouble());

  assert.equal(orchestrator.destroy(), true);
  assert.equal(orchestrator.destroy(), false);
  assert.equal(orchestrator.snapshot().destroyed, true);
  assert.throws(() => orchestrator.begin(), /has been destroyed/);
});

test("invalid diagnostic callbacks remain isolated", () => {
  const orchestrator = createPlaybackOrchestrator({
    reportLifecycle() {
      throw new Error("telemetry unavailable");
    },
    logInvalid() {
      throw new Error("logger unavailable");
    },
  });

  assert.doesNotThrow(() => orchestrator.begin());
  assert.doesNotThrow(() => orchestrator.playing());
});
