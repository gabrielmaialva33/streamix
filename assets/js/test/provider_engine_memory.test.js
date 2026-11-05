import assert from "node:assert/strict";
import test from "node:test";
import { ProviderEngineMemory } from "../player/provider_engine_memory.js";
import { clock } from "./support/playback_clock.js";

function harness() {
  const timerApi = clock();
  const recorded = [];
  const playback = { playing: true, currentTime: 0 };
  const memory = new ProviderEngineMemory({
    timerApi,
    now: timerApi.now,
    getPlayback: () => playback,
    record: (...args) => recorded.push(args),
  });
  const select = (options = {}) =>
    memory.select({
      providerId: "3",
      streamType: "mp4",
      engine: "avplayer",
      batchId: "session-1",
      ...options,
    });
  select();
  return { memory, timerApi, playback, recorded, select };
}

test("playing alone never learns; a first frame plus five seconds of advancing playback learns once", () => {
  const h = harness();
  h.memory.progress();
  h.timerApi.advance(10000);
  assert.deepEqual(h.recorded, []);
  h.memory.frame();
  h.playback.currentTime = 4;
  h.timerApi.advance(4999);
  assert.deepEqual(h.recorded, []);
  h.playback.currentTime = 5;
  h.timerApi.advance(1);
  assert.equal(h.recorded.length, 1);
  assert.equal(h.recorded[0][0], "provider:3:mp4");
  assert.equal(h.recorded[0][1], "avplayer");
  h.memory.progress();
  h.timerApi.advance(10000);
  assert.equal(h.recorded.length, 1);
});

test("pause/stall/static frame cannot count as stable and a later provider cannot inherit an old window", () => {
  const h = harness();
  h.memory.frame();
  h.timerApi.advance(4000);
  h.memory.pause();
  h.playback.playing = false;
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, []);
  h.playback.playing = true;
  h.memory.progress();
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, [], "a static frame isn't successful playback");
  h.memory.interrupt();
  h.playback.currentTime = 20;
  h.memory.progress();
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, [], "stall requires another frame signal");
  h.memory.frame();
  h.timerApi.advance(4000);
  h.select({ providerId: "4" });
  h.playback.currentTime = 30;
  h.timerApi.advance(1000);
  assert.deepEqual(h.recorded, []);
  h.memory.frame();
  h.playback.currentTime = 35;
  h.timerApi.advance(5000);
  assert.equal(h.recorded[0][0], "provider:4:mp4");
});

test("cleanup, unknown provider, and duplicate activation cannot manufacture provider evidence", () => {
  const h = harness();
  h.memory.frame();
  h.memory.clear();
  h.playback.currentTime = 10;
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, []);
  h.select({ providerId: null });
  h.memory.frame();
  h.playback.currentTime = 20;
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, []);
  h.select({ engine: "native" });
  h.memory.frame();
  h.playback.currentTime = 25;
  h.timerApi.advance(5000);
  assert.equal(h.recorded.length, 1);
  h.select({ engine: "native" });
  h.memory.frame();
  h.playback.currentTime = 40;
  h.timerApi.advance(5000);
  assert.equal(h.recorded.length, 1, "one engine success per batch even after reactivation");
  h.select({ engine: "native", batchId: "session-2" });
  h.memory.frame();
  h.playback.currentTime = 45;
  h.timerApi.advance(5000);
  assert.equal(h.recorded.length, 2);
});

test("a brief time tick followed by a frozen picture is not five seconds of stable playback", () => {
  const h = harness();
  h.memory.frame();
  h.playback.currentTime = 0.1;
  h.timerApi.advance(5000);
  assert.deepEqual(h.recorded, []);
});

test("a forward clock jump cannot manufacture a stable playback window", () => {
  const h = harness();
  h.memory.frame();
  h.timerApi.advance(4900);
  h.playback.currentTime = 30;
  h.timerApi.advance(100);
  assert.deepEqual(h.recorded, []);
});

test("AV first frame after 15 seconds never reinforces memory even after stable playback", () => {
  const timerApi = clock();
  const recorded = [];
  const playback = { playing: true, currentTime: 0 };
  const memory = new ProviderEngineMemory({
    timerApi,
    now: timerApi.now,
    getPlayback: () => playback,
    record: (...args) => recorded.push(args),
  });
  memory.select({
    providerId: "3",
    streamType: "mp4",
    engine: "avplayer",
    batchId: "slow",
    startedAt: 0,
    selectionReason: "provider_memory",
  });
  timerApi.advance(15001);
  memory.frame();
  playback.currentTime = 5;
  timerApi.advance(5000);
  assert.deepEqual(recorded, []);
  memory.select({
    providerId: "3",
    streamType: "mp4",
    engine: "native",
    batchId: "slow",
    startedAt: 0,
  });
  memory.frame();
  playback.currentTime = 10;
  timerApi.advance(5000);
  assert.equal(recorded.length, 1, "slow native success still replaces AV memory");
  assert.equal(recorded[0][1], "native");
});
