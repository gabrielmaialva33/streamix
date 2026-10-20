import assert from "node:assert/strict";
import test from "node:test";

import ProgressBar from "../hooks/progress_bar.js";

function createElementDouble(initialAttrs = {}) {
  const attributes = new Map(Object.entries(initialAttrs));
  const classes = new Set();
  const listeners = new Map();

  return {
    classList: {
      add: (...names) => {
        names.forEach((n) => {
          classes.add(n);
        });
      },
      remove: (...names) => {
        names.forEach((n) => {
          classes.delete(n);
        });
      },
      contains: (n) => classes.has(n),
    },
    style: {},
    getAttribute: (name) => attributes.get(name) || null,
    setAttribute: (name, value) => attributes.set(name, String(value)),
    addEventListener: (event, handler) => {
      if (!listeners.has(event)) listeners.set(event, []);
      listeners.get(event).push(handler);
    },
    removeEventListener: (event, handler) => {
      if (!listeners.has(event)) return;
      const filtered = listeners.get(event).filter((h) => h !== handler);
      listeners.set(event, filtered);
    },
    dispatchEvent: (event) => {
      const handlers = listeners.get(event.type) || [];
      handlers.forEach((h) => {
        h(event);
      });
    },
  };
}

test("ProgressBar keyboard navigation adjusts time and ARIA slider attributes (A2-C11)", () => {
  const progressContainer = createElementDouble({
    "aria-disabled": "false",
    "aria-valuemin": "0",
    "aria-valuemax": "100",
    "aria-valuenow": "50",
  });
  const progressPlayed = createElementDouble();

  let committedSeek = null;
  const hook = Object.assign(Object.create(ProgressBar), {
    progressContainer,
    progressPlayed,
    video: { duration: 100, currentTime: 50 },
    getVideoPlayerHook: () => ({
      getDuration: () => 100,
      getCurrentTime: () => 50,
      seekTo: (time) => {
        committedSeek = time;
      },
    }),
    commitSeek(time) {
      this.getVideoPlayerHook().seekTo(time);
    },
  });

  const dispatchKey = (key) => {
    let defaultPrevented = false;
    let stopped = false;
    const event = {
      key,
      preventDefault: () => {
        defaultPrevented = true;
      },
      stopPropagation: () => {
        stopped = true;
      },
    };
    ProgressBar.handleKeyDown.call(hook, event);
    return { defaultPrevented, stopped };
  };

  // ArrowRight: +5s
  let res = dispatchKey("ArrowRight");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 55);
  assert.equal(progressContainer.getAttribute("aria-valuenow"), "55");
  assert.equal(progressContainer.getAttribute("aria-valuetext"), "00:55 de 01:40");

  // ArrowLeft: -5s
  res = dispatchKey("ArrowLeft");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 45);
  assert.equal(progressContainer.getAttribute("aria-valuenow"), "45");

  // ArrowUp: +10s
  res = dispatchKey("ArrowUp");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 60);

  // ArrowDown: -10s
  res = dispatchKey("ArrowDown");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 40);

  // PageUp: +30s
  res = dispatchKey("PageUp");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 80);

  // PageDown: -30s
  res = dispatchKey("PageDown");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 20);

  // Home: seek 0
  res = dispatchKey("Home");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 0);
  assert.equal(progressContainer.getAttribute("aria-valuenow"), "0");
  assert.equal(progressContainer.getAttribute("aria-valuetext"), "00:00 de 01:40");

  // End: seek duration (100)
  res = dispatchKey("End");
  assert.equal(res.defaultPrevented, true);
  assert.equal(committedSeek, 100);
  assert.equal(progressContainer.getAttribute("aria-valuenow"), "100");
  assert.equal(progressContainer.getAttribute("aria-valuetext"), "01:40 de 01:40");
});

test("ProgressBar ignores keyboard events when aria-disabled is true", () => {
  const progressContainer = createElementDouble({ "aria-disabled": "true" });
  let committed = false;
  const hook = {
    progressContainer,
    commitSeek: () => {
      committed = true;
    },
  };

  const event = { key: "ArrowRight", preventDefault: () => {} };
  ProgressBar.handleKeyDown.call(hook, event);
  assert.equal(committed, false);
});
