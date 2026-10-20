import assert from "node:assert/strict";
import test from "node:test";
import ScrollHeader from "../hooks/scroll_header.js";

test("header becomes opaque immediately and restores scroll state after patches", () => {
  const previousWindow = globalThis.window;
  const previousFrame = globalThis.requestAnimationFrame;
  let listener;
  globalThis.window = {
    scrollY: 0,
    addEventListener: (_name, callback) => {
      listener = callback;
    },
    removeEventListener: (_name, callback) => {
      assert.equal(callback, listener);
    },
  };
  globalThis.requestAnimationFrame = (callback) => callback();
  try {
    const hook = { ...ScrollHeader, el: { dataset: {} } };
    hook.mounted();
    assert.equal(hook.el.dataset.scrolled, false);
    window.scrollY = 1;
    listener();
    assert.equal(hook.el.dataset.scrolled, true);
    hook.el.dataset.scrolled = false;
    hook.updated();
    assert.equal(hook.el.dataset.scrolled, true);
    window.scrollY = 0;
    hook.updated();
    assert.equal(hook.el.dataset.scrolled, false);
    hook.destroyed();
  } finally {
    globalThis.window = previousWindow;
    globalThis.requestAnimationFrame = previousFrame;
  }
});
