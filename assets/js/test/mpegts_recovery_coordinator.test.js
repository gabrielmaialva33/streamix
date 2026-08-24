import assert from "node:assert/strict";
import test from "node:test";

import {
  createMpegtsRecoveryCoordinator,
  MpegtsRecoveryCoordinator,
} from "../player/mpegts_recovery_coordinator.js";

const networkError = {
  errorType: "NetworkError",
  errorDetail: "NetworkTimeout",
};

const mediaError = {
  errorType: "MediaError",
  errorDetail: "MediaMseError",
};

const flush = () => new Promise((resolve) => setImmediate(resolve));

function createScheduler() {
  const scheduled = [];
  const cancelled = [];

  return {
    scheduled,
    cancelled,
    schedule(callback, delayMs) {
      const timer = { callback, delayMs };
      scheduled.push(timer);
      return timer;
    },
    cancelSchedule(timer) {
      cancelled.push(timer);
    },
  };
}

test("validates recovery boundaries and retry limits", () => {
  assert.throws(
    () => new MpegtsRecoveryCoordinator({ classify: true }),
    /classify boundary must be a function/,
  );
  assert.throws(
    () => new MpegtsRecoveryCoordinator({ maxNetworkAttempts: -1 }),
    /maxNetworkAttempts must be a non-negative integer/,
  );

  const coordinator = createMpegtsRecoveryCoordinator();
  assert.throws(
    () => coordinator.handle(networkError, { sessionId: -1 }),
    /sessionId must be a non-negative integer/,
  );
});

test("ignores recovered early EOF without teardown or recovery state", async () => {
  const recovering = [];
  let cleanupCalls = 0;
  const coordinator = createMpegtsRecoveryCoordinator({
    onRecovering: (decision) => recovering.push(decision.action),
  });

  const result = await coordinator.handle(
    {
      errorType: "NetworkError",
      errorDetail: "RecoveredEarlyEof",
    },
    {
      sessionId: 1,
      cleanup: async () => {
        cleanupCalls += 1;
        return true;
      },
    },
  );

  assert.equal(result, true);
  assert.equal(cleanupCalls, 0);
  assert.deepEqual(recovering, []);
  assert.deepEqual(coordinator.snapshot(), {
    networkAttempts: 0,
    recreateAttempts: 0,
    activeSessionId: null,
    recoveryActive: false,
    retryScheduled: false,
    destroyed: false,
  });
});

test("requests a fresh token without teardown", async () => {
  const calls = [];
  const coordinator = createMpegtsRecoveryCoordinator();

  const result = await coordinator.handle(
    {
      errorType: "NetworkError",
      errorDetail: "NetworkException",
      errorInfo: { response: { code: 403 } },
    },
    {
      sessionId: 2,
      cleanup: async () => calls.push("cleanup"),
      refreshToken: () => calls.push("refresh-token"),
    },
  );

  assert.equal(result, true);
  assert.deepEqual(calls, ["refresh-token"]);
});

test("deduplicates one scheduled retry until its callback finishes", async () => {
  const scheduler = createScheduler();
  const calls = [];
  const decisions = [];
  const coordinator = createMpegtsRecoveryCoordinator({
    maxNetworkAttempts: 2,
    schedule: scheduler.schedule,
    cancelSchedule: scheduler.cancelSchedule,
    onDecision: (decision, _error, snapshot) => decisions.push({ decision, snapshot }),
  });
  const context = {
    sessionId: 7,
    cleanup: async () => {
      calls.push("cleanup");
      return true;
    },
    isCurrent: () => true,
    retryMpegts: () => calls.push("retry-mpegts"),
  };

  const first = coordinator.handle(networkError, context);
  const duplicate = coordinator.handle(networkError, context);
  assert.equal(duplicate, first);

  await flush();
  assert.equal(scheduler.scheduled.length, 1);
  assert.equal(scheduler.scheduled[0].delayMs, 200);
  assert.deepEqual(calls, ["cleanup"]);
  assert.equal(coordinator.snapshot().recoveryActive, true);
  assert.equal(coordinator.snapshot().retryScheduled, true);
  assert.equal(decisions[0].snapshot.networkAttempts, 1);

  await scheduler.scheduled[0].callback();
  assert.equal(await first, true);
  assert.deepEqual(calls, ["cleanup", "retry-mpegts"]);
  assert.equal(coordinator.snapshot().recoveryActive, false);
  assert.equal(coordinator.snapshot().retryScheduled, false);
});

test("cancelling a delayed retry resolves the active recovery as false", async () => {
  const scheduler = createScheduler();
  const coordinator = createMpegtsRecoveryCoordinator({
    schedule: scheduler.schedule,
    cancelSchedule: scheduler.cancelSchedule,
  });

  const recovery = coordinator.handle(networkError, {
    sessionId: 8,
    cleanup: async () => true,
    isCurrent: () => true,
  });

  await flush();
  assert.equal(coordinator.snapshot().retryScheduled, true);

  coordinator.cancel();
  assert.equal(await recovery, false);
  assert.deepEqual(scheduler.cancelled, [scheduler.scheduled[0]]);
  assert.equal(coordinator.snapshot().retryScheduled, false);
  assert.equal(coordinator.snapshot().recoveryActive, false);
});

test("direct retry resets transport budgets only when the action executes", async () => {
  const coordinator = createMpegtsRecoveryCoordinator({
    schedule: (callback) => callback(),
  });

  await coordinator.handle(networkError, {
    sessionId: 9,
    cleanup: async () => true,
    retryMpegts: () => {},
  });
  assert.equal(coordinator.snapshot().networkAttempts, 1);

  let directRetries = 0;
  await coordinator.handle(networkError, {
    sessionId: 10,
    canTryDirect: true,
    cleanup: async () => true,
    retryDirect: () => {
      directRetries += 1;
    },
  });

  assert.equal(directRetries, 1);
  assert.equal(coordinator.snapshot().networkAttempts, 0);
  assert.equal(coordinator.snapshot().recreateAttempts, 0);
});

test("recreates MPEG-TS once before requesting the product fallback", async () => {
  const calls = [];
  const coordinator = createMpegtsRecoveryCoordinator({
    maxRecreateAttempts: 1,
  });

  await coordinator.handle(mediaError, {
    sessionId: 11,
    cleanup: async () => true,
    retryMpegts: () => calls.push("retry-mpegts"),
  });
  assert.equal(coordinator.snapshot().recreateAttempts, 1);

  await coordinator.handle(mediaError, {
    sessionId: 12,
    cleanup: async () => true,
    fallbackNative: () => calls.push("fallback-native"),
  });

  assert.deepEqual(calls, ["retry-mpegts", "fallback-native"]);
});

test("stale sessions stop after teardown before running a retry", async () => {
  const calls = [];
  const coordinator = createMpegtsRecoveryCoordinator({
    schedule: (callback) => callback(),
  });

  const result = await coordinator.handle(networkError, {
    sessionId: 13,
    cleanup: async () => {
      calls.push("cleanup");
      return true;
    },
    isCurrent: () => false,
    retryMpegts: () => calls.push("retry-mpegts"),
  });

  assert.equal(result, false);
  assert.deepEqual(calls, ["cleanup"]);
});

test("recovery failures are contained and diagnostic failures stay harmless", async () => {
  const failures = [];
  const coordinator = createMpegtsRecoveryCoordinator({
    onDecision() {
      throw new Error("telemetry unavailable");
    },
    onFailure(error) {
      failures.push(error.message);
      throw new Error("logger unavailable");
    },
  });

  const result = await coordinator.handle(networkError, {
    sessionId: 14,
    cleanup: async () => {
      throw new Error("teardown failed");
    },
  });

  assert.equal(result, false);
  assert.deepEqual(failures, ["teardown failed"]);
});

test("markRecovered resets attempts and destroy is idempotent", async () => {
  const coordinator = createMpegtsRecoveryCoordinator({
    schedule: (callback) => callback(),
  });

  await coordinator.handle(networkError, {
    sessionId: 15,
    cleanup: async () => true,
  });
  assert.equal(coordinator.snapshot().networkAttempts, 1);

  coordinator.markRecovered();
  assert.equal(coordinator.snapshot().networkAttempts, 0);
  assert.equal(coordinator.destroy(), true);
  assert.equal(coordinator.destroy(), false);
  assert.equal(coordinator.snapshot().destroyed, true);
  assert.throws(() => coordinator.handle(networkError, { sessionId: 16 }), /has been destroyed/);
});
