import assert from "node:assert/strict";
import test from "node:test";

import {
  AvPlayerPlaybackEngine,
  createAvPlayerPlaybackEngine,
} from "../player/avplayer_playback_engine.js";
import {
  assertPlaybackEngine,
  ENGINE_EVENT,
  ENGINE_ID,
  playbackEngineCapabilities,
} from "../player/engine_contract.js";
import { createPlaybackEngineAdapter } from "../player/playback_engine_adapter.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createWrapperClass() {
  const instances = [];
  class FakeWrapper {
    constructor(options) {
      this.options = options;
      this.calls = [];
      this.destroyed = false;
      this.currentTime = 12.5;
      this.duration = 100;
      this.playing = false;
      instances.push(this);
    }
    init() {
      this.calls.push(["init"]);
      return Promise.resolve();
    }
    async load(url, options) {
      this.calls.push(["load", url, options]);
    }
    async play() {
      this.calls.push(["play"]);
      this.playing = true;
    }
    async pause() {
      this.calls.push(["pause"]);
      this.playing = false;
    }
    async stop() {
      this.calls.push(["stop"]);
    }
    async seek(seconds) {
      this.calls.push(["seek", seconds]);
    }
    setVolume(volume) {
      this.calls.push(["setVolume", volume]);
    }
    getCurrentTime() {
      return this.currentTime;
    }
    getDuration() {
      return this.duration;
    }
    isPlaying() {
      return this.playing;
    }
    async getAudioTracks() {
      return [{ id: 0 }];
    }
    async getSubtitleTracks() {
      return [{ id: 1 }];
    }
    async selectAudioTrack(id) {
      this.calls.push(["selectAudioTrack", id]);
    }
    async selectSubtitleTrack(id) {
      this.calls.push(["selectSubtitleTrack", id]);
    }
    async loadExternalSubtitle(options) {
      this.calls.push(["loadExternalSubtitle", options]);
      return true;
    }
    setSubtitleDelay(ms) {
      this.calls.push(["setSubtitleDelay", ms]);
    }
    async destroy() {
      this.destroyed = true;
      this.calls.push(["destroy"]);
    }
  }
  return { FakeWrapper, instances };
}

function createEngine(overrides = {}) {
  const { FakeWrapper, instances } = createWrapperClass();
  const container = { id: "avplayer-mount" };
  const engine = createAvPlayerPlaybackEngine({
    AVPlayerWrapper: FakeWrapper,
    container,
    logger: silentLogger,
    ...overrides,
  });
  return { container, engine, wrapper: instances[0] };
}

test("validates its inputs and satisfies the playback engine contract", () => {
  assert.throws(
    () => createAvPlayerPlaybackEngine({ container: {} }),
    /requires the AVPlayerWrapper class/,
  );
  assert.throws(
    () => createAvPlayerPlaybackEngine({ AVPlayerWrapper: class {}, container: null }),
    /requires a container element/,
  );

  const { engine, wrapper, container } = createEngine();
  assert.ok(engine instanceof AvPlayerPlaybackEngine);
  assert.equal(assertPlaybackEngine(engine), engine);
  assert.equal(engine.id, ENGINE_ID.AVPLAYER);
  assert.equal(engine.client, wrapper);
  assert.equal(wrapper.options.container, container);

  const capabilities = playbackEngineCapabilities(engine);
  for (const method of [
    "init",
    "stop",
    "setVolume",
    "getCurrentTime",
    "getDuration",
    "isPlaying",
    "snapshot",
    "getAudioTracks",
    "getSubtitleTracks",
    "selectAudioTrack",
    "selectSubtitleTrack",
    "loadExternalSubtitle",
    "setSubtitleDelay",
    "on",
    "off",
  ]) {
    assert.equal(capabilities[method], true, `${method} must be a supported capability`);
  }
});

test("translates wrapper callbacks into the shared engine event vocabulary", () => {
  const { engine, wrapper } = createEngine();
  const events = [];
  for (const name of Object.values(ENGINE_EVENT)) {
    engine.on(name, (...args) => events.push([name, ...args]));
  }

  wrapper.options.onReady();
  wrapper.options.onPlay();
  wrapper.options.onTimeUpdate(42.25);
  wrapper.options.onTimeUpdate(-1);
  wrapper.options.onPause();
  wrapper.options.onEnded();
  const failure = new Error("decoder died");
  wrapper.options.onError(failure);

  assert.deepEqual(events, [
    ["ready"],
    ["playing"],
    ["timeupdate", 42.25],
    ["timeupdate", 0],
    ["paused"],
    ["ended"],
    ["error", failure],
  ]);
  assert.equal(engine.ready, true);
});

test("subscriptions can be removed and throwing handlers never break other listeners", () => {
  const { engine, wrapper } = createEngine();
  const seen = [];
  const unsubscribe = engine.on(ENGINE_EVENT.PLAYING, () => seen.push("first"));
  engine.on(ENGINE_EVENT.PLAYING, () => {
    throw new Error("boom");
  });
  engine.on(ENGINE_EVENT.PLAYING, () => seen.push("third"));

  wrapper.options.onPlay();
  assert.deepEqual(seen, ["first", "third"]);

  unsubscribe();
  wrapper.options.onPlay();
  assert.deepEqual(seen, ["first", "third", "third"]);

  assert.throws(() => engine.on(ENGINE_EVENT.PLAYING, null), /handler must be a function/);
});

test("delegates the contract surface to the wrapper with normalized inputs", async () => {
  const { engine, wrapper } = createEngine();

  await engine.init();
  await engine.load("https://example.test/movie.mkv", { ext: "mkv" });
  await engine.load({ url: "https://example.test/other.mp4" });
  await engine.play();
  await engine.seek(-5);
  await engine.seek("30");
  engine.setVolume(0.4);
  await engine.pause();
  await engine.stop();
  await engine.selectAudioTrack(2);
  await engine.selectSubtitleTrack(-1);
  await engine.loadExternalSubtitle({ source: "blob:x" });
  engine.setSubtitleDelay(250);

  assert.deepEqual(wrapper.calls, [
    ["init"],
    ["load", "https://example.test/movie.mkv", { ext: "mkv" }],
    ["load", "https://example.test/other.mp4", {}],
    ["play"],
    ["seek", 0],
    ["seek", 30],
    ["setVolume", 0.4],
    ["pause"],
    ["stop"],
    ["selectAudioTrack", 2],
    ["selectSubtitleTrack", -1],
    ["loadExternalSubtitle", { source: "blob:x" }],
    ["setSubtitleDelay", 250],
  ]);
  assert.throws(() => engine.load(""), /non-empty URL/);
  assert.deepEqual(await engine.getAudioTracks(), [{ id: 0 }]);
  assert.deepEqual(await engine.getSubtitleTracks(), [{ id: 1 }]);
  assert.equal(engine.getCurrentTime(), 12.5);
  assert.equal(engine.getDuration(), 100);
  assert.equal(engine.isPlaying(), false);
});

test("snapshot is bounded and teardown is idempotent, silences events and guards calls", async () => {
  const { engine, wrapper } = createEngine();
  wrapper.playing = true;
  wrapper.options.onReady();

  assert.deepEqual(engine.snapshot(), {
    engine: "avplayer",
    ready: true,
    destroyed: false,
    currentTime: 12.5,
    duration: 100,
    paused: false,
  });

  const events = [];
  engine.on(ENGINE_EVENT.ERROR, () => events.push("error"));

  assert.equal(await engine.destroy(), true);
  assert.equal(await engine.destroy(), false);
  assert.equal(wrapper.destroyed, true);
  assert.equal(wrapper.calls.filter(([name]) => name === "destroy").length, 1);

  wrapper.options.onError(new Error("late"));
  assert.deepEqual(events, [], "events after teardown are dropped");
  assert.deepEqual(engine.snapshot(), {
    engine: "avplayer",
    ready: false,
    destroyed: true,
    currentTime: 0,
    duration: 0,
    paused: true,
  });
  assert.throws(() => engine.load("https://example.test/x.mp4"), /has been destroyed/);
  assert.throws(() => engine.play(), /has been destroyed/);
  assert.equal(engine.seek(10), undefined, "soft controls tolerate teardown");
  assert.equal(engine.pause(), undefined);
  assert.equal(typeof engine.on(ENGINE_EVENT.PLAYING, () => {}), "function");
});

test("works behind the shared PlaybackEngineAdapter with adapter-level events", async () => {
  const { engine, wrapper } = createEngine();
  const adapter = createPlaybackEngineAdapter({ id: ENGINE_ID.AVPLAYER, engine });
  const events = [];
  const off = adapter.on(ENGINE_EVENT.PLAYING, () => events.push("playing"));
  adapter.on(ENGINE_EVENT.ERROR, (error) => events.push(error.message));

  wrapper.options.onPlay();
  wrapper.options.onError(new Error("late failure"));
  off();
  wrapper.options.onPlay();

  assert.deepEqual(events, ["playing", "late failure"]);
  assert.equal(adapter.snapshot().engine, "avplayer");
  await adapter.destroy();
  assert.equal(wrapper.destroyed, true);
});
