import assert from "node:assert/strict";
import test from "node:test";
import { nextTapGesture, pinchFit } from "../player/player_gestures.js";

test("side double taps start a seek chain; each later tap within 700ms repeats", () => {
  let tap = nextTapGesture(null, 0.1, 0);
  assert.equal(tap.action, null);
  tap = nextTapGesture(tap, 0.1, 200);
  assert.equal(tap.action, "seek-backward");
  tap = nextTapGesture(tap, 0.3, 850);
  assert.equal(tap.action, "seek-backward");
  tap = nextTapGesture(tap, 0.3, 1551);
  assert.equal(tap.action, null);
  tap = nextTapGesture(tap, 0.9, 1600);
  assert.equal(tap.action, null);
  assert.equal(nextTapGesture(tap, 0.9, 1800).action, "seek-forward");
});

test("the centre 20 percent toggles playback only on double tap, with exact boundaries", () => {
  const first = nextTapGesture(null, 0.4, 10);
  assert.equal(nextTapGesture(first, 0.59, 310).action, "toggle-play");
  assert.equal(nextTapGesture(first, 0.6, 100).action, null);
  assert.equal(nextTapGesture(first, 0.5, 311).action, null);
});

test("pinches need a meaningful distance change, and distinguish fit from fill", () => {
  assert.equal(pinchFit(100, 105), null);
  assert.equal(pinchFit(100, 120), "fill");
  assert.equal(pinchFit(100, 80), "fit");
  assert.equal(pinchFit(0, 100), null);
});
