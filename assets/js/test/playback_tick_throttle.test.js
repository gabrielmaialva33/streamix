import assert from "node:assert/strict";
import test from "node:test";

import { createPlaybackTickThrottle } from "../player/playback_tick_throttle.js";

test("limits UI work while keeping progress reports on a slower cadence", () => {
  let timestamp = 1_000;
  const throttle = createPlaybackTickThrottle({ now: () => timestamp });

  assert.deepEqual(throttle.next(), { reportProgress: false, updateUi: true });

  timestamp += 100;
  assert.deepEqual(throttle.next(), { reportProgress: false, updateUi: false });

  timestamp += 25;
  assert.deepEqual(throttle.next(), { reportProgress: false, updateUi: true });

  timestamp = 10_999;
  assert.deepEqual(throttle.next(), { reportProgress: false, updateUi: true });

  timestamp = 11_000;
  assert.deepEqual(throttle.next(), { reportProgress: true, updateUi: false });
});

test("recovers cleanly when the supplied clock restarts", () => {
  let timestamp = 5_000;
  const throttle = createPlaybackTickThrottle({ now: () => timestamp });

  throttle.next();
  timestamp = 100;

  assert.deepEqual(throttle.next(), { reportProgress: true, updateUi: true });
});

test("normalizes invalid intervals without suppressing the first UI update", () => {
  const throttle = createPlaybackTickThrottle({
    now: () => 0,
    progressIntervalMs: Number.NaN,
    uiIntervalMs: -1,
  });

  assert.deepEqual(throttle.next(), { reportProgress: false, updateUi: true });
});
