import assert from "node:assert/strict";
import test from "node:test";

import {
  createMpegtsPlaybackEngine,
  MpegtsPlaybackEngine,
} from "../player/mpegts_playback_engine.js";

function videoDouble(overrides = {}) {
  return {
    currentTime: 10,
    duration: 120,
    paused: true,
    ended: false,
    volume: 1,
    src: "",
    loadCalls: 0,
    playCalls: 0,
    pauseCalls: 0,
    removed: [],
    buffered: {
      length: 1,
      start: () => 0,
      end: () => 25,
    },
    load() {
      this.loadCalls += 1;
    },
    play() {
      this.playCalls += 1;
      this.paused = false;
      return Promise.resolve("playing");
    },
    pause() {
      this.pauseCalls += 1;
      this.paused = true;
    },
    removeAttribute(name) {
      this.removed.push(name);
      if (name === "src") this.src = "";
    },
    ...overrides,
  };
}

function playerDouble(overrides = {}) {
  const calls = [];
  const handlers = new Map();

  return {
    calls,
    handlers,
    mediaInfo: { videoCodec: "avc1.640028" },
    statisticsInfo: {
      droppedFrames: 2,
      decodedFrames: 240,
      speed: 1.25,
    },
    attachMediaElement(video) {
      calls.push(["attach", video]);
    },
    detachMediaElement() {
      calls.push(["detach"]);
    },
    load() {
      calls.push(["load"]);
    },
    unload() {
      calls.push(["unload"]);
    },
    play() {
      calls.push(["play"]);
      return Promise.resolve("player-playing");
    },
    pause() {
      calls.push(["pause"]);
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

test("validates the media element and mpegts.js client", () => {
  assert.throws(
    () => new MpegtsPlaybackEngine({ video: null, player: playerDouble() }),
    /requires an HTMLMediaElement-like video/,
  );

  assert.throws(
    () => new MpegtsPlaybackEngine({ video: videoDouble(), player: { load() {} } }),
    /missing required methods: attachMediaElement, unload, destroy/,
  );
});

test("attaches and loads the concrete player exactly once", () => {
  const video = videoDouble();
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({ video, player });

  const source = engine.load({
    url: "https://example.test/live.ts",
    type: "mpegts",
    isLive: true,
  });
  engine.load(source);

  assert.deepEqual(source, {
    url: "https://example.test/live.ts",
    type: "mpegts",
    live: true,
  });
  assert.deepEqual(
    player.calls.map(([name]) => name),
    ["attach", "load"],
  );
});

test("soft reload unloads without replacing the player instance", () => {
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({
    video: videoDouble(),
    player,
    source: "https://example.test/live.ts",
  });

  engine.load();
  const client = engine.client;
  const source = engine.reload("https://example.test/fallback.ts");

  assert.equal(engine.client, client);
  assert.equal(source.url, "https://example.test/fallback.ts");
  assert.deepEqual(
    player.calls.map(([name]) => name),
    ["attach", "load", "unload", "load"],
  );
});

test("implements the common playback controls", async () => {
  const video = videoDouble();
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({ video, player });

  engine.load();
  assert.equal(await engine.play(), "player-playing");
  engine.pause();
  assert.equal(engine.seek(500), 120);
  assert.equal(video.currentTime, 120);
  assert.equal(engine.setVolume(-1), 0);
  assert.equal(video.volume, 0);
  assert.equal(engine.getCurrentTime(), 120);
  assert.equal(engine.getDuration(), 120);
});

test("falls back to the media element when player play/pause are unavailable", async () => {
  const video = videoDouble();
  const player = playerDouble();
  delete player.play;
  delete player.pause;

  const engine = createMpegtsPlaybackEngine({ video, player });
  assert.equal(await engine.play(), "playing");
  engine.pause();

  assert.equal(video.playCalls, 1);
  assert.equal(video.pauseCalls, 1);
});

test("publishes immutable transport diagnostics", () => {
  const video = videoDouble();
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({
    video,
    player,
    source: { url: "https://example.test/live.ts", isLive: true },
  });
  engine.load();
  video.paused = false;

  const snapshot = engine.snapshot();

  assert.deepEqual(snapshot, {
    engine: "mpegts",
    attached: true,
    loaded: true,
    destroyed: false,
    source: {
      url: "https://example.test/live.ts",
      type: null,
      live: true,
    },
    currentTime: 10,
    duration: 120,
    paused: false,
    ended: false,
    live: true,
    bufferedSeconds: 15,
    droppedFrames: 2,
    decodedFrames: 240,
    speed: 1.25,
    mediaInfo: { videoCodec: "avc1.640028" },
    statistics: {
      droppedFrames: 2,
      decodedFrames: 240,
      speed: 1.25,
    },
  });
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.statistics), true);
});

test("forwards player events", () => {
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({ video: videoDouble(), player });
  const handler = () => {};

  engine.on("error", handler);
  assert.equal(player.handlers.get("error"), handler);
  engine.off("error", handler);
  assert.equal(player.handlers.has("error"), false);
});

test("destroy is idempotent and owns unload/detach/destroy ordering", () => {
  const video = videoDouble({ src: "https://example.test/live.ts" });
  const player = playerDouble();
  const engine = createMpegtsPlaybackEngine({
    video,
    player,
    resetSourceOnDestroy: true,
  });

  engine.load();
  assert.equal(engine.destroy(), true);
  assert.equal(engine.destroy(), false);

  assert.deepEqual(
    player.calls.map(([name]) => name),
    ["attach", "load", "unload", "detach", "destroy"],
  );
  assert.deepEqual(video.removed, ["src"]);
  assert.equal(video.loadCalls, 1);
  assert.throws(() => engine.play(), /has been destroyed/);
});

test("preserves the shared media source by default", () => {
  const video = videoDouble({ src: "https://example.test/live.ts" });
  const engine = createMpegtsPlaybackEngine({
    video,
    player: playerDouble(),
  });

  engine.load();
  engine.destroy();

  assert.equal(video.src, "https://example.test/live.ts");
  assert.deepEqual(video.removed, []);
});
