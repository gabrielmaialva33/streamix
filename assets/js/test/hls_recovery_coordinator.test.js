import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyHlsRecovery,
  createHlsRecoveryCoordinator,
  HLS_RECOVERY_OPERATION,
  HLS_RECOVERY_OUTCOME,
  HLS_RECOVERY_REASON,
  normalizeHlsRecoveryEvent,
} from "../player/hls_recovery_coordinator.js";

function loaderDouble({ softReload = true } = {}) {
  const calls = [];

  return {
    calls,
    canSoftReload(type) {
      calls.push(["canSoftReload", type]);
      return softReload;
    },
    loadHlsSoft(url) {
      calls.push(["loadHlsSoft", url]);
      return Promise.resolve("soft-reloaded");
    },
    startLoad() {
      calls.push(["startLoad"]);
      return "started";
    },
    recoverMediaError() {
      calls.push(["recoverMediaError"]);
      return "recovered";
    },
  };
}

function scheduledHarness() {
  const scheduled = [];
  const cancelled = [];

  return {
    scheduled,
    cancelled,
    schedule(callback, delayMs) {
      const timer = { callback, delayMs, cancelled: false };
      scheduled.push(timer);
      return timer;
    },
    cancelSchedule(timer) {
      timer.cancelled = true;
      cancelled.push(timer);
    },
  };
}

async function settleScheduled(timer) {
  timer.callback();
  await Promise.resolve();
  await Promise.resolve();
}

test("normalizes raw hls.js errors into a stable bounded event", () => {
  assert.deepEqual(
    normalizeHlsRecoveryEvent({
      fatal: true,
      type: "networkError",
      details: "manifestLoadError",
      response: { code: "403" },
      ignored: "value",
    }),
    {
      fatal: true,
      type: "networkError",
      details: "manifestLoadError",
      responseCode: 403,
    },
  );

  assert.deepEqual(normalizeHlsRecoveryEvent(null), {
    fatal: false,
    type: "unknown",
    details: "unknown",
    responseCode: null,
  });
});

test("classifies non-fatal and authorization events without transport recovery", () => {
  const nonFatal = classifyHlsRecovery({
    fatal: false,
    type: "networkError",
  });
  const authorization = classifyHlsRecovery({
    fatal: true,
    type: "networkError",
    response: { code: 401 },
  });

  assert.equal(nonFatal.outcome, HLS_RECOVERY_OUTCOME.IGNORED);
  assert.equal(nonFatal.reason, HLS_RECOVERY_REASON.NON_FATAL);
  assert.equal(authorization.outcome, HLS_RECOVERY_OUTCOME.REFRESH_TOKEN);
  assert.equal(authorization.reason, HLS_RECOVERY_REASON.AUTHORIZATION);
});

test("schedules bounded manifest soft reloads and then asks the product for fallback", async () => {
  const loader = loaderDouble();
  const timers = scheduledHarness();
  const coordinator = createHlsRecoveryCoordinator(timers);
  const context = {
    loader,
    url: "https://example.test/live.m3u8",
    isCurrent: () => true,
  };
  const error = {
    fatal: true,
    type: "networkError",
    details: "manifestLoadError",
  };

  const first = coordinator.handle(error, context);
  assert.equal(first.decision.outcome, HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED);
  assert.equal(first.decision.operation, HLS_RECOVERY_OPERATION.SOFT_RELOAD);
  assert.equal(first.decision.nextAttempts, 1);
  assert.equal(first.decision.delayMs, 1_000);
  assert.equal(timers.scheduled.length, 1);

  await settleScheduled(timers.scheduled[0]);
  assert.ok(
    loader.calls.some(
      (call) => call[0] === "loadHlsSoft" && call[1] === "https://example.test/live.m3u8",
    ),
  );

  const second = coordinator.handle(error, context);
  assert.equal(second.decision.nextAttempts, 2);
  assert.equal(second.decision.delayMs, 2_000);
  await settleScheduled(timers.scheduled[1]);

  const exhausted = coordinator.handle(error, context);
  assert.equal(exhausted.decision.outcome, HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED);
  assert.equal(exhausted.decision.reason, HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE);
});

test("restarts network loading before escalating to a soft reload", async () => {
  const loader = loaderDouble();
  const coordinator = createHlsRecoveryCoordinator();
  const context = {
    loader,
    url: "https://example.test/live.m3u8",
    isCurrent: () => true,
  };
  const error = {
    fatal: true,
    type: "networkError",
    details: "fragLoadError",
  };

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const recovery = coordinator.handle(error, context);
    assert.equal(recovery.decision.operation, HLS_RECOVERY_OPERATION.START_LOAD);
    assert.equal(recovery.decision.nextAttempts, attempt);
    await recovery.promise;
  }

  const reload = coordinator.handle(error, context);
  assert.equal(reload.decision.operation, HLS_RECOVERY_OPERATION.SOFT_RELOAD);
  assert.equal(reload.decision.reason, HLS_RECOVERY_REASON.NETWORK_SOFT_RELOAD);
  assert.equal(reload.decision.nextAttempts, 0);
  await reload.promise;

  assert.equal(loader.calls.filter((call) => call[0] === "startLoad").length, 3);
  assert.equal(loader.calls.filter((call) => call[0] === "loadHlsSoft").length, 1);
});

test("recovers media errors before rebuilding the HLS source", async () => {
  const loader = loaderDouble();
  const coordinator = createHlsRecoveryCoordinator();
  const context = {
    loader,
    url: "https://example.test/movie.m3u8",
    isCurrent: () => true,
  };
  const error = { fatal: true, type: "mediaError" };

  const first = coordinator.handle(error, context);
  const second = coordinator.handle(error, context);
  await Promise.all([first.promise, second.promise]);

  const reload = coordinator.handle(error, context);
  assert.equal(reload.decision.operation, HLS_RECOVERY_OPERATION.SOFT_RELOAD);
  assert.equal(reload.decision.reason, HLS_RECOVERY_REASON.MEDIA_SOFT_RELOAD);
  await reload.promise;

  assert.equal(loader.calls.filter((call) => call[0] === "recoverMediaError").length, 2);
});

test("guards stale sessions before invoking the loader", async () => {
  const loader = loaderDouble();
  const coordinator = createHlsRecoveryCoordinator();

  const recovery = coordinator.handle(
    { fatal: true, type: "mediaError" },
    {
      loader,
      url: "https://example.test/movie.m3u8",
      isCurrent: () => false,
    },
  );

  await recovery.promise;
  assert.equal(loader.calls.filter((call) => call[0] === "recoverMediaError").length, 0);
});

test("reports operation failures without turning diagnostics into a second failure", async () => {
  const failures = [];
  const coordinator = createHlsRecoveryCoordinator({
    onFailure(error, decision) {
      failures.push({ error, decision });
      throw new Error("diagnostic callback failed");
    },
  });

  const recovery = coordinator.handle(
    { fatal: true, type: "mediaError" },
    {
      loader: {
        canSoftReload: () => false,
        recoverMediaError() {
          throw new Error("decode recovery failed");
        },
      },
      url: "https://example.test/movie.m3u8",
      isCurrent: () => true,
    },
  );

  await assert.doesNotReject(recovery.promise);
  assert.equal(failures.length, 1);
  assert.equal(failures[0].error.message, "decode recovery failed");
  assert.equal(failures[0].decision.operation, HLS_RECOVERY_OPERATION.RECOVER_MEDIA);
});

test("cancels scheduled work, resets attempts after recovery, and destroys idempotently", () => {
  const timers = scheduledHarness();
  const coordinator = createHlsRecoveryCoordinator(timers);
  const loader = loaderDouble();
  const context = {
    loader,
    url: "https://example.test/live.m3u8",
    isCurrent: () => true,
  };

  coordinator.handle(
    {
      fatal: true,
      type: "networkError",
      details: "manifestParsingError",
    },
    context,
  );

  assert.deepEqual(coordinator.snapshot(), {
    attempts: 1,
    scheduled: true,
    recovering: false,
    destroyed: false,
    lastDecision: coordinator.snapshot().lastDecision,
  });

  coordinator.markRecovered();
  assert.equal(timers.cancelled.length, 1);
  assert.equal(coordinator.snapshot().attempts, 0);
  assert.equal(coordinator.snapshot().scheduled, false);
  assert.equal(coordinator.destroy(), true);
  assert.equal(coordinator.destroy(), false);
  assert.throws(() => coordinator.handle({ fatal: false }, context), /has been destroyed/);
});

test("validates configurable coordinator boundaries", () => {
  assert.throws(
    () => createHlsRecoveryCoordinator({ onFailure: true }),
    /onFailure boundary must be a function/,
  );
  assert.throws(
    () => createHlsRecoveryCoordinator({ limits: { networkRestarts: -1 } }),
    /networkRestarts must be a non-negative integer/,
  );
});
