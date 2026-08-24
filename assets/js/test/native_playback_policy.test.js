import assert from "node:assert/strict";
import test from "node:test";

import { createNativePlaybackEngine } from "../player/native_playback_engine.js";

function createVideo() {
  return {
    src: "",
    currentTime: 12,
    duration: 120,
    paused: false,
    ended: false,
    volume: 1,
    readyState: 4,
    networkState: 1,
    load() {},
    play() {
      this.paused = false;
      return Promise.resolve();
    },
    pause() {
      this.paused = true;
    },
    addEventListener() {},
    removeEventListener() {},
    removeAttribute() {},
  };
}

test("native pause preserves the hook intentional-pause boundary", () => {
  const video = createVideo();
  const calls = [];
  const engine = createNativePlaybackEngine({
    video,
    beforePause: () => calls.push("beforePause"),
    resetSourceOnDestroy: false,
  });

  engine.pause();

  assert.deepEqual(calls, ["beforePause"]);
  assert.equal(video.paused, true);
});

test("native seek preserves buffering policy callbacks and normalized targets", () => {
  const video = createVideo();
  const calls = [];
  const engine = createNativePlaybackEngine({
    video,
    beforeSeek: (target) => calls.push(["beforeSeek", target]),
    afterSeek: (target) => calls.push(["afterSeek", target]),
    resetSourceOnDestroy: false,
  });

  assert.equal(engine.seek(-30), 0);
  assert.equal(video.currentTime, 0);
  assert.deepEqual(calls, [
    ["beforeSeek", 0],
    ["afterSeek", 0],
  ]);
});
