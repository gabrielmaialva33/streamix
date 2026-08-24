import assert from "node:assert/strict";
import test from "node:test";

import { createMediaElementEngine, MediaElementEngine } from "../player/media_element_engine.js";

function createVideo(overrides = {}) {
  const calls = [];
  const listeners = new Map();

  return {
    calls,
    listeners,
    currentTime: 12,
    duration: 120,
    paused: true,
    ended: false,
    volume: 1,
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
    ...overrides,
  };
}

test("requires an HTMLMediaElement-like playback surface", () => {
  assert.throws(
    () => new MediaElementEngine({ video: null }),
    /requires an HTMLMediaElement-like object/,
  );

  assert.throws(
    () => new MediaElementEngine({ video: { play() {} } }),
    /requires an HTMLMediaElement-like object/,
  );
});

test("delegates source loading and transport ownership through explicit callbacks", async () => {
  const video = createVideo();
  const calls = [];
  const engine = createMediaElementEngine({
    video,
    loadSource(source, options) {
      calls.push(["load", source, options]);
      return Promise.resolve("loaded");
    },
    destroySource() {
      calls.push(["destroy"]);
      return Promise.resolve("destroyed");
    },
  });

  assert.equal(await engine.load("channel.m3u8", { lowLatency: true }), "loaded");
  assert.equal(await engine.destroy(), "destroyed");
  assert.deepEqual(calls, [["load", "channel.m3u8", { lowLatency: true }], ["destroy"]]);
});

test("controls the shared media element and preserves seek policies as callbacks", async () => {
  const video = createVideo();
  const policyCalls = [];
  const engine = createMediaElementEngine({
    video,
    beforePause: () => policyCalls.push(["beforePause"]),
    beforeSeek: (target) => policyCalls.push(["beforeSeek", target]),
    afterSeek: (target) => policyCalls.push(["afterSeek", target]),
  });

  assert.equal(await engine.play(), "playing");
  assert.equal(engine.isPlaying(), true);

  engine.pause();
  assert.equal(engine.isPlaying(), false);

  assert.equal(engine.seek(-30), 0);
  assert.equal(video.currentTime, 0);
  assert.deepEqual(video.calls, [["play"], ["pause"]]);
  assert.deepEqual(policyCalls, [["beforePause"], ["beforeSeek", 0], ["afterSeek", 0]]);
});

test("normalizes media measurements and clamps volume", () => {
  const video = createVideo({ currentTime: Number.NaN, duration: Infinity });
  const engine = createMediaElementEngine({ video });

  assert.equal(engine.getCurrentTime(), 0);
  assert.equal(engine.getDuration(), 0);

  engine.setVolume(4);
  assert.equal(video.volume, 1);
  engine.setVolume(-2);
  assert.equal(video.volume, 0);
  engine.setVolume(0.35);
  assert.equal(video.volume, 0.35);
});

test("forwards media events without owning listener registration policy", () => {
  const video = createVideo();
  const engine = createMediaElementEngine({ video });
  const handler = () => {};

  engine.on("playing", handler);
  assert.equal(video.listeners.get("playing"), handler);

  engine.off("playing", handler);
  assert.equal(video.listeners.has("playing"), false);
});

test("default lifecycle callbacks are side-effect free", async () => {
  const video = createVideo();
  const engine = createMediaElementEngine({ video });

  assert.equal(await engine.load("movie.mp4"), undefined);
  assert.equal(await engine.destroy(), undefined);
  assert.equal(video.currentTime, 12);
  assert.equal(video.paused, true);
});
