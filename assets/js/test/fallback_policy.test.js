import assert from "node:assert/strict";
import test from "node:test";

import { evaluateFallbackAttempt } from "../player/fallback_policy.js";

const policy = {
  maxAttempts: 5,
  cooldowns: [2_000, 5_000, 10_000, 20_000, 30_000],
};

test("allows the first fallback attempt immediately", () => {
  assert.deepEqual(
    evaluateFallbackAttempt(
      {
        ...policy,
        attempts: 0,
        lastAttemptAt: 0,
      },
      1_000,
    ),
    {
      allowed: true,
      attempts: 0,
      remainingMs: 0,
      reason: null,
    },
  );
});

test("blocks a repeated fallback until its exponential cooldown expires", () => {
  assert.deepEqual(
    evaluateFallbackAttempt(
      {
        ...policy,
        attempts: 2,
        lastAttemptAt: 10_000,
      },
      13_000,
    ),
    {
      allowed: false,
      attempts: 2,
      remainingMs: 2_000,
      reason: "cooldown",
    },
  );
});

test("resets an exhausted circuit only after the maximum cooldown", () => {
  const exhausted = {
    ...policy,
    attempts: 5,
    lastAttemptAt: 10_000,
  };

  assert.deepEqual(evaluateFallbackAttempt(exhausted, 39_999), {
    allowed: false,
    attempts: 5,
    remainingMs: 1,
    reason: "max_attempts",
  });

  assert.deepEqual(evaluateFallbackAttempt(exhausted, 40_000), {
    allowed: true,
    attempts: 0,
    remainingMs: 0,
    reason: null,
  });
});
