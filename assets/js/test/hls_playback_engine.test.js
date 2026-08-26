import assert from "node:assert/strict";
import test from "node:test";

import { playbackEngineCapabilities } from "../player/engine_contract.js";
import { createHlsPlaybackEngine, HlsPlaybackEngine } from "../player/hls_playback_engine.js";

function videoDouble(overrides = {}) {
  return {
    currentTime: 0,
    duration: 120,
    paused: true,
    ended: false,
    volume: 1,
    src: "",
    loadCalls: 0,
    pauseCalls: 0,
    removedAttributes: [],
    play() {
      this.paused = false;
      return Promise.resolve("playing");
    },
    pause() {
      this.paused = true;
      this.pauseCalls += 1;
    },
    load() {
      this.loadCalls += 1;
    },
    removeAttribute(name) {
      this.removedAttributes.push(name);
      if (name === "src") this.src = "";
    },
    ...overrides,
  };
}

function hlsDouble(overrides = {}) {
  const calls = [];
  const handlers = new Map();

  return {
    calls,
    handlers,
    currentLevel: 2,
    loadLevel: 3,
    autoLevelEnabled: true,
    audioTrack: 1,
    subtitleTrack: -1,
    audioTracks: [
      { id: "en", name: "English", lang: "en" },
      { id: "pt", name: "Português", lang: "pt-BR" },
    ],
    subtitleTracks: [{ id: "pt", name: "Português", lang: "pt-BR" }],
    bandwidthEstimate: 4_500_000,
    latency: 2.4,
    targetLatency: 3,
    liveSyncPosition: 18,
    loadSource(url) {
      calls.push(["loadSource", url]);
    },
    attachMedia(video) {
      calls.push(["attachMedia", video]);
    },
    stopLoad() {
      calls.push(["stopLoad"]);
    },
    startLoad(position) {
      calls.push(["startLoad", position]);
    },
    destroy() {
      calls.push(["destroy"]);
    },
    on(event, handler) {
      handlers.set(event, handler);
    },
    off(event, handler) {
      if (handlers.get(event) === handler) handlers.delete(event);
    },
    ...overrides,
  };
}

test("requires a media element and the hls.js lifecycle surface", () => {
  assert.throws(
    () => new HlsPlaybackEngine({ video: null, hls: hlsDouble() }),
    /requires an HTMLMediaElement-like video/,
  );

  assert.throws(
    () => new HlsPlaybackEngine({ video: videoDouble(), hls: { loadSource() {} } }),
    /hls\.js client is missing methods/,
  );
});

test("loads the source before attaching the shared media element", () => {
  const video = videoDouble();
  const hls = hlsDouble();
  const engine = createHlsPlaybackEngine({ video, hls });

  assert.equal(engine.load("https://example.test/live.m3u8"), hls);
  assert.deepEqual(hls.calls, [
    ["loadSource", "https://example.test/live.m3u8"],
    ["attachMedia", video],
  ]);
  assert.equal(engine.client, hls);
  assert.equal(engine.snapshot().source.url, "https://example.test/live.m3u8");
});

test("soft reload preserves the hls.js instance and restarts loading", () => {
  const hls = hlsDouble();
  const engine = createHlsPlaybackEngine({ video: videoDouble(), hls });

  engine.load("https://example.test/one.m3u8");
  hls.calls.length = 0;

  assert.equal(engine.reload("https://example.test/two.m3u8", { startPosition: 14 }), hls);
  assert.deepEqual(hls.calls, [
    ["stopLoad"],
    ["loadSource", "https://example.test/two.m3u8"],
    ["startLoad", 14],
  ]);
  assert.equal(engine.snapshot().source.url, "https://example.test/two.m3u8");
});

test("implements the shared playback controls through the media element", async () => {
  const video = videoDouble();
  const engine = createHlsPlaybackEngine({ video, hls: hlsDouble() });

  assert.equal(await engine.play(), "playing");
  assert.equal(engine.isPlaying(), true);

  engine.pause();
  assert.equal(video.pauseCalls, 1);
  assert.equal(engine.isPlaying(), false);

  assert.equal(engine.seek(500), 120);
  assert.equal(video.currentTime, 120);
  assert.equal(engine.setVolume(-5), 0);
  assert.equal(engine.setVolume(2), 1);
});

test("owns HLS audio and subtitle discovery and selection", () => {
  const hls = hlsDouble();
  const engine = createHlsPlaybackEngine({ video: videoDouble(), hls });

  const audioTracks = engine.getAudioTracks();
  const subtitleTracks = engine.getSubtitleTracks();

  assert.equal(Object.isFrozen(audioTracks), true);
  assert.equal(Object.isFrozen(audioTracks[0]), true);
  assert.equal(audioTracks[0].selectionId, 0);
  assert.equal(audioTracks[0].active, false);
  assert.equal(audioTracks[1].selectionId, 1);
  assert.equal(audioTracks[1].active, true);
  assert.equal(audioTracks[1].selected, true);
  assert.equal(subtitleTracks[0].selectionId, 0);
  assert.equal(subtitleTracks[0].active, false);

  assert.equal(engine.selectAudioTrack(0), 0);
  assert.equal(hls.audioTrack, 0);
  assert.equal(engine.selectSubtitleTrack(0), 0);
  assert.equal(hls.subtitleTrack, 0);
  assert.equal(engine.selectAudioTrack("invalid"), false);
  assert.equal(engine.selectAudioTrack(null), false);
  assert.equal(engine.selectSubtitleTrack(""), false);
  assert.equal(hls.audioTrack, 0);
  assert.equal(hls.subtitleTrack, 0);
});

test("exposes HLS diagnostics in an immutable snapshot", () => {
  const engine = createHlsPlaybackEngine({
    video: videoDouble({ currentTime: 9, duration: 90, paused: false }),
    hls: hlsDouble(),
  });

  engine.load("https://example.test/live.m3u8");
  const snapshot = engine.snapshot();

  assert.deepEqual(snapshot, {
    engine: "hls",
    attached: true,
    destroyed: false,
    source: { url: "https://example.test/live.m3u8" },
    currentTime: 9,
    duration: 90,
    paused: false,
    ended: false,
    currentLevel: 2,
    loadLevel: 3,
    autoLevelEnabled: true,
    bandwidthEstimate: 4_500_000,
    latency: 2.4,
    targetLatency: 3,
    liveSyncPosition: 18,
  });
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.source), true);
});

test("forwards hls.js events and reports optional capabilities", () => {
  const hls = hlsDouble();
  const engine = createHlsPlaybackEngine({ video: videoDouble(), hls });
  const handler = () => {};

  engine.on("manifestParsed", handler);
  assert.equal(hls.handlers.get("manifestParsed"), handler);
  engine.off("manifestParsed", handler);
  assert.equal(hls.handlers.has("manifestParsed"), false);

  const capabilities = playbackEngineCapabilities(engine);
  assert.equal(capabilities.snapshot, true);
  assert.equal(capabilities.setVolume, true);
  assert.equal(capabilities.getAudioTracks, true);
  assert.equal(capabilities.getSubtitleTracks, true);
  assert.equal(capabilities.selectAudioTrack, true);
  assert.equal(capabilities.selectSubtitleTrack, true);
});

test("destroys the hls.js client once without resetting the shared source by default", () => {
  const video = videoDouble({ src: "blob:shared" });
  const hls = hlsDouble();
  const engine = createHlsPlaybackEngine({ video, hls });

  assert.equal(engine.destroy(), true);
  assert.equal(engine.destroy(), false);
  assert.deepEqual(hls.calls, [["destroy"]]);
  assert.equal(video.src, "blob:shared");
  assert.equal(engine.client, null);
  assert.equal(engine.snapshot().destroyed, true);
  assert.throws(() => engine.play(), /has been destroyed/);
});

test("can explicitly reset the shared media element during teardown", () => {
  const video = videoDouble({ src: "blob:hls" });
  const engine = createHlsPlaybackEngine({
    video,
    hls: hlsDouble(),
    resetSourceOnDestroy: true,
  });

  engine.destroy();

  assert.deepEqual(video.removedAttributes, ["src"]);
  assert.equal(video.loadCalls, 1);
});
