import assert from "node:assert/strict";
import test from "node:test";
import { clampSeekTime, relativeSeekTarget } from "../player/playback_time.js";

test("clamps a relative seek to the finite media timeline", () => {
  assert.equal(relativeSeekTarget(4, -10, 120), 0);
  assert.equal(relativeSeekTarget(115, 10, 120), 120);
  assert.equal(relativeSeekTarget(60, -10, 120), 50);
});

test("rejects non-seekable and malformed timelines", () => {
  assert.equal(relativeSeekTarget(20, 10, Number.POSITIVE_INFINITY), null);
  assert.equal(relativeSeekTarget(Number.NaN, 10, 120), null);
  assert.equal(relativeSeekTarget(20, Number.NaN, 120), null);
  assert.equal(clampSeekTime(20, 0), null);
  assert.equal(clampSeekTime(20, -1), null);
});

test("clamps absolute seeks without leaking NaN", () => {
  assert.equal(clampSeekTime(-5, 100), 0);
  assert.equal(clampSeekTime(105, 100), 100);
  assert.equal(clampSeekTime(42.5, 100), 42.5);
  assert.equal(clampSeekTime(Number.NaN, 100), null);
});
