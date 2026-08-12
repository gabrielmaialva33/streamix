import assert from "node:assert/strict";
import test from "node:test";

import { NativeBufferingController } from "../player/native_buffering_controller.js";

const createHarness = ({ contentType = "vod", now = 10_000 } = {}) => {
  const calls = [];
  const timers = [];
  let currentNow = now;
  const video = {
    buffered: {
      end: () => 20,
      length: 1,
    },
    currentTime: 10,
    paused: false,
    play: async () => {
      calls.push("play");
    },
    readyState: 2,
  };
  const controller = new NativeBufferingController({
    contentType,
    emit: (event, payload) => calls.push([event, payload]),
    logger: { debug: (...args) => calls.push(["debug", ...args]) },
    metrics: {
      markPlaying: () => calls.push("markPlaying"),
      setBuffering: (buffering) => calls.push(["setBuffering", buffering]),
    },
    now: () => currentNow,
    playerUI: {
      hideError: () => calls.push("hideError"),
      hideLoading: () => calls.push("hideLoading"),
      showLoading: () => calls.push("showLoading"),
    },
    timerApi: {
      clearTimeout: (id) => calls.push(["clearTimeout", id]),
      setTimeout(callback, delay) {
        timers.push({ callback, delay });
        return timers.length;
      },
    },
    video,
  });

  return {
    calls,
    controller,
    setNow(value) {
      currentNow = value;
    },
    timers,
    video,
  };
};

test("debounces live buffering before exposing loading state", () => {
  const harness = createHarness({ contentType: "live" });

  harness.controller.handleWaiting();
  assert.equal(harness.timers[0].delay, 650);
  assert.equal(harness.calls.includes("showLoading"), false);

  harness.timers[0].callback();
  assert.equal(harness.calls.includes("showLoading"), true);
  assert.equal(
    harness.calls.some(([event, payload]) => event === "buffering" && payload.buffering),
    true,
  );
});

test("honors the VOD seek grace period and resumes only a previously playing video", async () => {
  const harness = createHarness({ contentType: "vod", now: 1_000 });

  harness.controller.prepareSeek();
  harness.controller.handleSeeking();
  harness.controller.handleWaiting();
  assert.equal(harness.timers[0].delay, 1_600);

  harness.setNow(2_600);
  harness.timers[0].callback();
  harness.controller.handleSeeked();
  await Promise.resolve();

  assert.equal(harness.calls.includes("showLoading"), true);
  assert.equal(harness.calls.includes("play"), true);
});

test("playing cancels pending buffering and publishes one healthy state", () => {
  const harness = createHarness();
  harness.controller.handleWaiting();
  harness.controller.handlePlaying();

  assert.deepEqual(harness.calls, [
    ["clearTimeout", 1],
    ["buffering", { buffering: false }],
    "markPlaying",
    "hideLoading",
    "hideError",
  ]);
});

test("teardown suppresses a buffering callback that was already queued", () => {
  const harness = createHarness();
  harness.controller.handleWaiting();
  harness.controller.destroy();
  harness.timers[0].callback();

  assert.equal(harness.calls.includes("showLoading"), false);
  assert.equal(
    harness.calls.some(
      (entry) => Array.isArray(entry) && entry[0] === "buffering" && entry[1].buffering,
    ),
    false,
  );
});
