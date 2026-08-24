import assert from "node:assert/strict";
import test from "node:test";

import { playbackEngineCapabilities, playbackEngineViolations } from "../player/engine_contract.js";
import {
  createNativePlaybackEngine,
  NativePlaybackEngine,
} from "../player/native_playback_engine.js";

function createVideo(overrides = {}) {
  const calls = [];
  const listeners = new Map();

  return {
    calls,
    listeners,
    src: "",
    preload: "metadata",
    crossOrigin: null,
    playsInline: false,
    autoplay: false,
    currentTime: 0,
    duration: 120,
    paused: true,
    ended: false,
    muted: false,
    volume: 1,
    playbackRate: 1,
    readyState: 1,
    networkState: 1,
    load() {
      calls.push(["load"]);
    },
    play() {
      calls.push(["play"]);
      this.paused = false;
      return Promise.resolve("playing");
    },
    pause() {
      calls.push(["pause"]);
      this.paused = true;
    },
    addEventListener(event, handler) {
      listeners.set(event, handler);
    },
    removeEventListener(event, handler) {
      if (listeners.get(event) === handler) listeners.delete(event);
    },
    removeAttribute(name) {
      calls.push(["removeAttribute", name]);
      if (name === "src") this.src = "";
    },
    ...overrides,
  };
}

test("requires a load-capable media element", () => {
  assert.throws(
    () => new NativePlaybackEngine({ video: null }),
    /requires an HTMLMediaElement-like object with load/,
  );

  assert.throws(
    () =>
      new NativePlaybackEngine({
        video: { play() {}, pause() {} },
      }),
    /requires an HTMLMediaElement-like object with load/,
  );
});

test("satisfies the common engine contract and exposes native capabilities", () => {
  const engine = createNativePlaybackEngine({ video: createVideo() });

  assert.deepEqual(playbackEngineViolations(engine), []);
  assert.deepEqual(playbackEngineCapabilities(engine), {
    init: false,
    stop: false,
    setVolume: true,
    getCurrentTime: true,
    getDuration: true,
    isPlaying: true,
    snapshot: true,
    getAudioTracks: false,
    getSubtitleTracks: false,
    selectAudioTrack: false,
    selectSubtitleTrack: false,
    loadExternalSubtitle: false,
    setSubtitleDelay: false,
    on: true,
    off: true,
  });
});

test("loads a normalized native source and applies browser options", () => {
  const video = createVideo();
  const engine = createNativePlaybackEngine({ video });

  const source = engine.load(
    { url: "  https://example.test/movie.mp4  ", type: "video/mp4" },
    {
      preload: "auto",
      crossOrigin: "anonymous",
      playsInline: true,
      autoplay: true,
      muted: true,
      startTime: 18,
    },
  );

  assert.deepEqual(source, {
    url: "https://example.test/movie.mp4",
    type: "video/mp4",
    preload: "auto",
    crossOrigin: "anonymous",
    playsInline: true,
    autoplay: true,
    muted: true,
    startTime: 18,
  });
  assert.equal(Object.isFrozen(source), true);
  assert.equal(video.src, source.url);
  assert.equal(video.preload, "auto");
  assert.equal(video.crossOrigin, "anonymous");
  assert.equal(video.playsInline, true);
  assert.equal(video.autoplay, true);
  assert.equal(video.muted, true);
  assert.equal(video.currentTime, 18);
  assert.deepEqual(video.calls, [["load"]]);
});

test("defers the initial seek until metadata and removes the listener", () => {
  const video = createVideo({ readyState: 0 });
  const engine = createNativePlaybackEngine({ video });

  engine.load("https://example.test/movie.mp4", { startTime: 25 });
  assert.equal(video.currentTime, 0);
  assert.equal(video.listeners.has("loadedmetadata"), true);

  video.readyState = 1;
  video.listeners.get("loadedmetadata")();

  assert.equal(video.currentTime, 25);
  assert.equal(video.listeners.has("loadedmetadata"), false);
});

test("delegates playback controls and publishes an immutable snapshot", async () => {
  const video = createVideo();
  const engine = createNativePlaybackEngine({ video });
  engine.load("https://example.test/movie.mp4");

  assert.equal(await engine.play(), "playing");
  assert.equal(engine.isPlaying(), true);
  engine.pause();
  assert.equal(engine.isPlaying(), false);
  assert.equal(engine.seek(-10), 0);
  engine.setVolume(0.4);

  const snapshot = engine.snapshot();
  assert.deepEqual(snapshot, {
    engine: "native",
    attached: true,
    destroyed: false,
    source: engine.source,
    currentTime: 0,
    duration: 120,
    paused: true,
    ended: false,
    muted: false,
    volume: 0.4,
    playbackRate: 1,
    readyState: 1,
    networkState: 1,
  });
  assert.equal(Object.isFrozen(snapshot), true);
});

test("destroys idempotently and resets the media source once", () => {
  const video = createVideo();
  const engine = createNativePlaybackEngine({ video });
  engine.load("https://example.test/movie.mp4");

  assert.equal(engine.destroy(), true);
  assert.equal(engine.destroy(), false);
  assert.equal(video.src, "");
  assert.deepEqual(video.calls, [["load"], ["pause"], ["removeAttribute", "src"], ["load"]]);
  assert.deepEqual(engine.snapshot(), {
    engine: "native",
    attached: false,
    destroyed: true,
    source: null,
    currentTime: 0,
    duration: 0,
    paused: true,
  });
  assert.throws(() => engine.play(), /has been destroyed/);
});

test("can release ownership without resetting the shared media source", () => {
  const video = createVideo();
  const engine = createNativePlaybackEngine({
    video,
    resetSourceOnDestroy: false,
  });
  engine.load("https://example.test/movie.mp4");

  engine.destroy();

  assert.equal(video.src, "https://example.test/movie.mp4");
  assert.deepEqual(video.calls, [["load"], ["pause"]]);
});
