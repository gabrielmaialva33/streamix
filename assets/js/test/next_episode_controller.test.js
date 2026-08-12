import assert from "node:assert/strict";
import test from "node:test";

import { NextEpisodeController } from "../player/next_episode_controller.js";

const createClassList = (...initial) => {
  const values = new Set(initial);
  return {
    add(...names) {
      for (const name of names) values.add(name);
    },
    contains(name) {
      return values.has(name);
    },
    remove(...names) {
      for (const name of names) values.delete(name);
    },
  };
};

const createHarness = (episode = { id: 9, title: "Episode 9" }) => {
  const playButton = {};
  const cancelButton = {};
  const countdownBar = { style: {} };
  const overlay = {
    classList: createClassList("hidden", "translate-x-4"),
    querySelector(selector) {
      return {
        "#cancel-next-btn": cancelButton,
        "#next-countdown-bar": countdownBar,
        "#play-next-btn": playButton,
      }[selector];
    },
  };
  const clearedIntervals = [];
  const scheduler = {
    clearInterval(id) {
      clearedIntervals.push(id);
    },
    clearTimeout() {},
    requestAnimationFrame(callback) {
      callback();
    },
    setInterval(callback) {
      scheduler.intervalCallback = callback;
      return 17;
    },
    setTimeout(callback) {
      scheduler.timeoutCallback = callback;
      return 23;
    },
  };
  const windowRef = { location: { href: "about:blank" } };
  const controller = new NextEpisodeController({
    documentRef: { createElement() {}, head: { appendChild() {} } },
    episode,
    hlsSupported: () => false,
    logger: { debug() {}, warn() {} },
    root: {
      querySelector: (selector) => (selector === "#next-episode-overlay" ? overlay : null),
    },
    scheduler,
    windowRef,
  });

  return {
    cancelButton,
    clearedIntervals,
    controller,
    countdownBar,
    overlay,
    playButton,
    scheduler,
    windowRef,
  };
};

test("owns the next-episode overlay countdown and navigation lifecycle", () => {
  const harness = createHarness();

  harness.controller.check(90, 100);
  assert.equal(harness.overlay.classList.contains("hidden"), false);
  assert.equal(harness.overlay.classList.contains("opacity-100"), true);

  harness.scheduler.intervalCallback();
  assert.equal(harness.countdownBar.style.width, "90%");

  harness.playButton.onclick();
  assert.equal(harness.windowRef.location.href, "/watch/episode/9");
  assert.deepEqual(harness.clearedIntervals, [17]);
});

test("cleans handlers and timers when the controller is destroyed", () => {
  const harness = createHarness();
  harness.controller.show();
  harness.controller.destroy();

  assert.equal(harness.playButton.onclick, null);
  assert.equal(harness.cancelButton.onclick, null);
  assert.deepEqual(harness.clearedIntervals, [17]);
  assert.equal(harness.controller.destroyed, true);
});

test("does not create an HLS preloader after teardown wins the import race", async () => {
  let resolveHls;
  let instances = 0;
  const Hls = class {
    static Events = { ERROR: "error", MANIFEST_PARSED: "manifest" };

    constructor() {
      instances += 1;
    }
  };
  const hlsPromise = new Promise((resolve) => {
    resolveHls = resolve;
  });
  const preconnect = { remove() {} };
  const controller = new NextEpisodeController({
    documentRef: {
      createElement: () => preconnect,
      head: { appendChild() {} },
    },
    episode: {
      id: 10,
      stream_url: "https://cdn.example/episode.m3u8",
      type: "episode",
    },
    hlsLoader: () => hlsPromise,
    hlsSupported: () => true,
    logger: { debug() {}, warn() {} },
    root: null,
    scheduler: globalThis,
    streamType: () => "hls",
    windowRef: { location: {} },
  });

  const preload = controller.preload();
  controller.destroy();
  resolveHls(Hls);
  await preload;

  assert.equal(instances, 0);
  assert.equal(controller.preloader, null);
});
