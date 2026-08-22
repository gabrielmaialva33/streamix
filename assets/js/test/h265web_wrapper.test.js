import assert from "node:assert/strict";
import test from "node:test";
import { H265webWrapper } from "../media/h265web_wrapper.js";

function createWrapper() {
  return new H265webWrapper({
    video: { style: {} },
    mountEl: {
      classList: { add() {}, remove() {} },
      firstChild: null,
      removeChild() {},
    },
  });
}

test("tracks and emits h265web playback activity independently from the native video", async () => {
  const calls = [];
  const wrapper = createWrapper();
  wrapper.player = {
    async play() {
      calls.push("player-play");
    },
    pause() {
      calls.push("player-pause");
    },
  };
  wrapper.on("playing", () => calls.push("playing"));
  wrapper.on("paused", () => calls.push("paused"));

  assert.equal(wrapper.isPlaying(), false);
  await wrapper.play();
  assert.equal(wrapper.isPlaying(), true);
  wrapper.pause();
  assert.equal(wrapper.isPlaying(), false);
  assert.deepEqual(calls, ["player-play", "playing", "player-pause", "paused"]);
});

test("does not report playing when h265web play rejects", async () => {
  const wrapper = createWrapper();
  wrapper.player = {
    async play() {
      throw new Error("decoder failed");
    },
  };

  await assert.rejects(wrapper.play(), /decoder failed/);
  assert.equal(wrapper.isPlaying(), false);
});
