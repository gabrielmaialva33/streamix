import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_EVENT, ENGINE_ID } from "../player/engine_contract.js";
import {
  createPlaybackEngineAdapter,
  PlaybackEngineAdapter,
} from "../player/playback_engine_adapter.js";

function createEngine(overrides = {}) {
  const calls = [];
  const handlers = new Map();

  const engine = {
    calls,
    handlers,
    init() {
      calls.push(["init"]);
      return Promise.resolve("initialized");
    },
    load(source, options) {
      calls.push(["load", source, options]);
      return Promise.resolve("loaded");
    },
    play() {
      calls.push(["play"]);
      return Promise.resolve("playing");
    },
    pause() {
      calls.push(["pause"]);
    },
    stop() {
      calls.push(["stop"]);
      return Promise.resolve("stopped");
    },
    seek(seconds) {
      calls.push(["seek", seconds]);
      return Promise.resolve(seconds);
    },
    destroy() {
      calls.push(["destroy"]);
      return Promise.resolve("destroyed");
    },
    setVolume(volume) {
      calls.push(["setVolume", volume]);
    },
    getCurrentTime() {
      return 42.5;
    },
    getDuration() {
      return 120;
    },
    isPlaying() {
      return true;
    },
    getAudioTracks() {
      return [{ id: 1 }];
    },
    getSubtitleTracks() {
      return [{ id: 2 }];
    },
    selectAudioTrack(id) {
      calls.push(["selectAudioTrack", id]);
    },
    selectSubtitleTrack(id) {
      calls.push(["selectSubtitleTrack", id]);
    },
    loadExternalSubtitle(options) {
      calls.push(["loadExternalSubtitle", options]);
      return Promise.resolve("subtitle-loaded");
    },
    setSubtitleDelay(delayMs) {
      calls.push(["setSubtitleDelay", delayMs]);
    },
    on(event, handler) {
      handlers.set(event, handler);
    },
    off(event, handler) {
      if (handlers.get(event) === handler) handlers.delete(event);
    },
    ...overrides,
  };

  return engine;
}

test("validates the concrete engine contract at construction", () => {
  assert.throws(
    () => new PlaybackEngineAdapter({ id: ENGINE_ID.AVBRIDGE, engine: null }),
    /requires an engine object/,
  );

  assert.throws(
    () =>
      new PlaybackEngineAdapter({
        id: ENGINE_ID.AVBRIDGE,
        engine: { load() {} },
      }),
    /missing required methods: play, pause, seek, destroy/,
  );

  assert.throws(
    () =>
      new PlaybackEngineAdapter({
        id: "invented",
        engine: createEngine(),
      }),
    /requires a known engine id/,
  );
});

test("delegates the stable playback surface without exposing implementation details", async () => {
  const engine = createEngine();
  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.AVBRIDGE,
    engine,
  });

  assert.equal(adapter.id, ENGINE_ID.AVBRIDGE);
  assert.equal(await adapter.init(), "initialized");
  assert.equal(await adapter.load("movie.mkv", { startTime: 12 }), "loaded");
  assert.equal(await adapter.play(), "playing");
  adapter.pause();
  assert.equal(await adapter.stop(), "stopped");
  assert.equal(await adapter.seek(9.5), 9.5);
  adapter.setVolume(0.75);
  adapter.selectAudioTrack(3);
  adapter.selectSubtitleTrack(4);
  assert.equal(await adapter.loadExternalSubtitle({ url: "subtitle.vtt" }), "subtitle-loaded");
  adapter.setSubtitleDelay(250);

  assert.deepEqual(adapter.getAudioTracks(), [{ id: 1 }]);
  assert.deepEqual(adapter.getSubtitleTracks(), [{ id: 2 }]);
  assert.deepEqual(engine.calls, [
    ["init"],
    ["load", "movie.mkv", { startTime: 12 }],
    ["play"],
    ["pause"],
    ["stop"],
    ["seek", 9.5],
    ["setVolume", 0.75],
    ["selectAudioTrack", 3],
    ["selectSubtitleTrack", 4],
    ["loadExternalSubtitle", { url: "subtitle.vtt" }],
    ["setSubtitleDelay", 250],
  ]);
});

test("normalizes seek input and publishes a bounded immutable snapshot", async () => {
  const engine = createEngine({
    getCurrentTime: () => Number.NaN,
    getDuration: () => Infinity,
    isPlaying: () => false,
  });
  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.AVBRIDGE,
    engine,
  });

  await adapter.seek(-50);
  assert.deepEqual(engine.calls.at(-1), ["seek", 0]);

  const snapshot = adapter.snapshot();
  assert.deepEqual(snapshot, {
    engine: ENGINE_ID.AVBRIDGE,
    currentTime: 0,
    duration: 0,
    paused: true,
    destroyed: false,
  });
  assert.equal(Object.isFrozen(snapshot), true);
});

test("translates normalized event names and returns an unsubscribe function", () => {
  const engine = createEngine();
  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.AVBRIDGE,
    engine,
    eventMap: {
      [ENGINE_EVENT.ERROR]: "engine-error",
    },
  });
  const handler = () => {};

  const unsubscribe = adapter.on(ENGINE_EVENT.ERROR, handler);
  assert.equal(engine.handlers.get("engine-error"), handler);

  unsubscribe();
  assert.equal(engine.handlers.has("engine-error"), false);
});

test("teardown is idempotent and soft controls tolerate cleanup races", async () => {
  let resolveDestroy;
  const engine = createEngine({
    destroy() {
      engine.calls.push(["destroy"]);
      return new Promise((resolve) => {
        resolveDestroy = resolve;
      });
    },
  });
  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.AVBRIDGE,
    engine,
  });

  const firstDestroy = adapter.destroy();
  assert.deepEqual(engine.calls.at(-1), ["destroy"]);
  const secondDestroy = adapter.destroy();

  assert.equal(firstDestroy, secondDestroy);
  assert.equal(adapter.destroyed, true);
  assert.equal(adapter.pause(), undefined);
  assert.equal(adapter.seek(15), undefined);
  assert.throws(() => adapter.play(), /has been destroyed/);

  resolveDestroy("done");
  await firstDestroy;

  assert.deepEqual(
    engine.calls.filter(([method]) => method === "destroy"),
    [["destroy"]],
  );
  assert.deepEqual(adapter.snapshot(), {
    engine: ENGINE_ID.AVBRIDGE,
    currentTime: 0,
    duration: 0,
    paused: true,
    destroyed: true,
  });
});

test("can release a borrowed engine without destroying the transport owner", async () => {
  const engine = createEngine();
  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.HLS,
    engine,
    ownsEngine: false,
  });

  assert.equal(adapter.wraps(engine), true);
  await adapter.destroy();

  assert.equal(adapter.destroyed, true);
  assert.equal(adapter.wraps(engine), false);
  assert.deepEqual(
    engine.calls.filter(([method]) => method === "destroy"),
    [],
  );
});

test("optional capabilities degrade to safe defaults", () => {
  const engine = createEngine();
  delete engine.getCurrentTime;
  delete engine.getDuration;
  delete engine.isPlaying;
  delete engine.getAudioTracks;
  delete engine.getSubtitleTracks;
  delete engine.setVolume;

  const adapter = createPlaybackEngineAdapter({
    id: ENGINE_ID.AVBRIDGE,
    engine,
  });

  assert.equal(adapter.supports("setVolume"), false);
  assert.equal(adapter.setVolume(1), undefined);
  assert.equal(adapter.getCurrentTime(), 0);
  assert.equal(adapter.getDuration(), 0);
  assert.equal(adapter.isPlaying(), false);
  assert.deepEqual(adapter.getAudioTracks(), []);
  assert.deepEqual(adapter.getSubtitleTracks(), []);
});
