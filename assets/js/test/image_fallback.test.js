import assert from "node:assert/strict";
import test from "node:test";
import ImageFallback from "../hooks/image_fallback.js";

function element() {
  const classes = new Set();
  const listeners = new Map();
  return {
    complete: true,
    naturalHeight: 0,
    classList: {
      add: (v) => classes.add(v),
      remove: (v) => classes.delete(v),
      contains: (v) => classes.has(v),
    },
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
    listeners,
  };
}
test("missing, cached failures, recovery and replaced image nodes share the fallback", () => {
  let img = null;
  const fallback = element();
  fallback.classList.add("hidden");
  const hook = {
    ...ImageFallback,
    el: { querySelector: (selector) => (selector.startsWith("img") ? img : fallback) },
  };
  hook.mounted();
  assert.equal(fallback.classList.contains("hidden"), false);
  img = element();
  hook.updated();
  assert.equal(img.classList.contains("hidden"), true);
  img.naturalHeight = 100;
  img.listeners.get("load")();
  assert.equal(fallback.classList.contains("hidden"), true);
  assert.equal(img.classList.contains("hidden"), false);
  const old = img;
  img = element();
  img.complete = false;
  hook.updated();
  assert.equal(old.listeners.size, 0);
  img.listeners.get("error")();
  assert.equal(fallback.classList.contains("hidden"), false);
  hook.destroyed();
  assert.equal(img.listeners.size, 0);
});
