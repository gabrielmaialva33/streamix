import assert from "node:assert/strict";
import test from "node:test";
import { PlaybackRecoveryGuard } from "../player/playback_recovery_guard.js";

import { clock } from "./support/playback_clock.js";

test("startup and recovery deadlines terminate once, even across repeated retries", () => {
  const timerApi = clock();
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onExhausted: (reason) => reasons.push(reason),
  });
  guard.begin();
  timerApi.advance(29000);
  guard.recover();
  timerApi.advance(1000);
  assert.deepEqual(reasons, ["startup_deadline"]);
  assert.equal(guard.attempt(), false);
  timerApi.advance(100000);
  assert.equal(reasons.length, 1);
  guard.begin();
  guard.playing();
  guard.recover();
  timerApi.advance(20000);
  assert.deepEqual(reasons, ["startup_deadline", "recovery_deadline"]);
});

test("brief playing does not reset the rolling retry budget; stable playback does", () => {
  const timerApi = clock();
  let stable = 0;
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onStable: () => stable++,
    onExhausted: (reason) => reasons.push(reason),
  });
  guard.begin();
  for (let i = 0; i < 6; i++) {
    assert.equal(guard.attempt(), true);
    guard.playing();
    timerApi.advance(1000);
  }
  assert.equal(guard.attempt(), false);
  assert.deepEqual(reasons, ["retry_budget"]);
  guard.begin();
  guard.attempt();
  guard.playing();
  timerApi.advance(19999);
  assert.equal(stable, 0);
  guard.playing(); // duplicate playing must not postpone stability
  timerApi.advance(1);
  assert.equal(stable, 1);
  for (let i = 0; i < 6; i++) assert.equal(guard.attempt(), true);
  guard.destroy();
  timerApi.advance(100000);
  assert.equal(reasons.length, 1);
});

test("pause interrupts stability and a new stall keeps its original deadline", () => {
  const timerApi = clock();
  let stable = 0;
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onStable: () => stable++,
    onExhausted: (reason) => reasons.push(reason),
  });
  guard.begin();
  guard.playing();
  timerApi.advance(15000);
  guard.pause();
  timerApi.advance(10000);
  assert.equal(stable, 0);
  guard.recover();
  timerApi.advance(19000);
  guard.recover();
  timerApi.advance(1000);
  assert.deepEqual(reasons, ["recovery_deadline"]);
});

test("autoplay/user pause suspends the deadline without forgiving retries", () => {
  const timerApi = clock();
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onExhausted: (reason) => reasons.push(reason),
  });
  guard.begin();
  guard.attempt();
  guard.suspend();
  timerApi.advance(100000);
  assert.deepEqual(reasons, []);
  guard.resume();
  timerApi.advance(30000);
  assert.deepEqual(reasons, ["startup_deadline"]);
});

test("AV bootstrap has its own budget, then first frame; neither phase renews the total ceiling", () => {
  const timerApi = clock();
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onExhausted: (r) => reasons.push(r),
  });
  guard.begin();
  guard.bootstrap();
  timerApi.advance(55000);
  assert.deepEqual(reasons, []);
  guard.awaitFrame();
  timerApi.advance(29999);
  assert.deepEqual(reasons, []);
  timerApi.advance(1);
  assert.deepEqual(reasons, ["startup_deadline"]);
  guard.begin();
  guard.bootstrap();
  timerApi.advance(59000);
  guard.bootstrap();
  timerApi.advance(1000);
  assert.equal(reasons.length, 2, "repeat bootstrap must not buy another minute");
});

test("a deadline offers exactly one bounded recovery before terminal, including hung bootstrap", () => {
  const timerApi = clock();
  const reasons = [];
  let recoveries = 0;
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onStartupDeadline: () => {
      recoveries++;
      return true;
    },
    onExhausted: (r) => reasons.push(r),
  });
  guard.begin();
  guard.bootstrap();
  timerApi.advance(60000);
  assert.equal(recoveries, 1);
  assert.equal(guard.terminal, false);
  guard.awaitFrame(); // late bootstrap completion must not reset the fallback budget
  timerApi.advance(20000);
  assert.deepEqual(reasons, ["recovery_deadline"]);
  assert.equal(recoveries, 1);
  timerApi.advance(100000);
  assert.equal(reasons.length, 1);
});
