import assert from "node:assert/strict";
import test from "node:test";

import {
  createPlaybackEngineTransitionController,
  PLAYBACK_ENGINE_TRANSITION_PHASE,
  PlaybackEngineTransitionController,
} from "../player/playback_engine_transition_controller.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function createHarness(overrides = {}) {
  const calls = [];
  const destroyed = [];
  const errors = [];
  const snapshots = [];
  let currentSession = overrides.currentSession ?? 0;

  const controller = createPlaybackEngineTransitionController({
    beginSession() {
      calls.push("begin");
      currentSession += 1;
      return currentSession;
    },
    isSessionCurrent(sessionId) {
      return overrides.isSessionCurrent
        ? overrides.isSessionCurrent(sessionId)
        : sessionId === currentSession;
    },
    async drainTeardown(context) {
      calls.push(`drain:${context.sessionId}`);
      return overrides.drainTeardown?.(context);
    },
    async destroyEngine(engine, context) {
      calls.push(`destroy:${engine.id}`);
      destroyed.push(engine);
      return overrides.destroyEngine?.(engine, context);
    },
    onError(operation, error, context) {
      errors.push({ context, error, operation });
      overrides.onError?.(operation, error, context);
    },
    onStateChange(snapshot) {
      snapshots.push(snapshot);
      overrides.onStateChange?.(snapshot);
    },
  });

  return {
    calls,
    controller,
    destroyed,
    errors,
    setCurrentSession(sessionId) {
      currentSession = sessionId;
    },
    snapshots,
  };
}

function transitionOptions(harness, overrides = {}) {
  const engine = overrides.engine ?? { id: "avplayer" };
  return {
    key: "native-to-avplayer",
    capture: () => {
      harness.calls.push("capture");
      return { resumeTime: 42, shouldPlay: true };
    },
    prepare: ({ sessionId }) => harness.calls.push(`prepare:${sessionId}`),
    releasePrevious: ({ sessionId }) => harness.calls.push(`release:${sessionId}`),
    createEngine: ({ sessionId }) => {
      harness.calls.push(`create:${sessionId}`);
      return engine;
    },
    initializeEngine: ({ engine: created }) => harness.calls.push(`initialize:${created.id}`),
    loadEngine: ({ engine: created }) => harness.calls.push(`load:${created.id}`),
    registerEngine: ({ engine: created }) => harness.calls.push(`register:${created.id}`),
    restoreEngine: ({ engine: created, capture }) =>
      harness.calls.push(`restore:${created.id}:${capture.resumeTime}`),
    activateEngine: ({ engine: created }) => harness.calls.push(`activate:${created.id}`),
    complete: ({ engine: created }) => {
      harness.calls.push(`complete:${created.id}`);
      return created;
    },
    rollbackEngine: ({ engine: created }) => harness.calls.push(`rollback:${created.id}`),
    ...overrides,
  };
}

function recoveryOptions(harness, overrides = {}) {
  const engine = overrides.engine ?? { id: "avplayer" };
  return {
    key: "avplayer-to-native-recovery",
    sourceSessionId: 7,
    engine,
    capture: () => {
      harness.calls.push("capture-recovery");
      return { resumeTime: 24 };
    },
    prepare: ({ sourceSessionId }) => harness.calls.push(`prepare-recovery:${sourceSessionId}`),
    releasePrevious: ({ sourceSessionId }) =>
      harness.calls.push(`release-recovery:${sourceSessionId}`),
    restoreNative: ({ capture, sessionId }) =>
      harness.calls.push(`restore-native:${sessionId}:${capture.resumeTime}`),
    activateNative: ({ sessionId }) => harness.calls.push(`activate-native:${sessionId}`),
    complete: ({ sessionId }) => {
      harness.calls.push(`complete-recovery:${sessionId}`);
      return sessionId;
    },
    ...overrides,
  };
}

test("validates controller and transition boundaries", async () => {
  assert.throws(() => new PlaybackEngineTransitionController(), /requires beginSession\(\)/);

  const harness = createHarness();
  assert.throws(
    () => harness.controller.transition({ activateEngine() {} }),
    /requires createEngine\(\)/,
  );
  assert.throws(
    () => harness.controller.transition({ createEngine() {} }),
    /requires activateEngine\(\)/,
  );
});

test("runs one native-to-engine transaction in deterministic order", async () => {
  const harness = createHarness();
  const engine = { id: "avplayer" };

  const result = await harness.controller.transition(transitionOptions(harness, { engine }));

  assert.strictEqual(result, engine);
  assert.deepEqual(harness.calls, [
    "capture",
    "begin",
    "prepare:1",
    "release:1",
    "drain:1",
    "create:1",
    "initialize:avplayer",
    "load:avplayer",
    "register:avplayer",
    "restore:avplayer:42",
    "activate:avplayer",
    "complete:avplayer",
  ]);
  assert.deepEqual(harness.destroyed, []);
  assert.deepEqual(harness.controller.snapshot(), {
    active: false,
    destroyed: false,
    errorName: null,
    key: null,
    phase: PLAYBACK_ENGINE_TRANSITION_PHASE.IDLE,
    revision: 1,
    sessionId: null,
  });
});

test("reuses a supplied startup session without beginning a second session", async () => {
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };

  const result = await harness.controller.transition(
    transitionOptions(harness, {
      engine,
      key: "startup-avplayer",
      sessionId: 7,
    }),
  );

  assert.strictEqual(result, engine);
  assert.equal(harness.calls.includes("begin"), false);
  assert.deepEqual(harness.calls, [
    "capture",
    "prepare:7",
    "release:7",
    "drain:7",
    "create:7",
    "initialize:avplayer",
    "load:avplayer",
    "register:avplayer",
    "restore:avplayer:42",
    "activate:avplayer",
    "complete:avplayer",
  ]);
});

test("rejects a supplied startup session that is already stale", async () => {
  const harness = createHarness({ currentSession: 8 });

  const result = await harness.controller.transition(
    transitionOptions(harness, {
      key: "startup-avplayer",
      sessionId: 7,
    }),
  );

  assert.equal(result, false);
  assert.deepEqual(harness.calls, ["capture"]);
  assert.equal(harness.destroyed.length, 0);
  assert.ok(
    harness.snapshots.some(({ phase }) => phase === PLAYBACK_ENGINE_TRANSITION_PHASE.STALE),
  );
});

test("publishes immutable bounded lifecycle snapshots", async () => {
  const harness = createHarness();

  await harness.controller.transition(transitionOptions(harness));

  assert.ok(harness.snapshots.length > 5);
  assert.equal(harness.snapshots.every(Object.isFrozen), true);
  const phases = harness.snapshots.map(({ phase }) => phase);
  for (const phase of [
    PLAYBACK_ENGINE_TRANSITION_PHASE.CAPTURING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.PREPARING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.DRAINING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.CREATING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.LOADING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.RESTORING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.ACTIVATING,
    PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETED,
  ]) {
    assert.ok(phases.includes(phase), `missing phase ${phase}`);
  }
});

test("deduplicates concurrent transition requests", async () => {
  const creation = deferred();
  const harness = createHarness();
  const options = transitionOptions(harness, {
    createEngine: async ({ sessionId }) => {
      harness.calls.push(`create:${sessionId}`);
      return creation.promise;
    },
  });

  const first = harness.controller.transition(options);
  const second = harness.controller.transition(transitionOptions(harness, { key: "duplicate" }));

  assert.strictEqual(first, second);
  assert.equal(harness.controller.active, true);
  creation.resolve({ id: "avplayer" });
  await first;
  assert.equal(harness.calls.filter((call) => call === "begin").length, 1);
  assert.equal(harness.calls.filter((call) => call.startsWith("create:")).length, 1);
});

test("drops a stale completion and destroys its provisional engine exactly once", async () => {
  const loading = deferred();
  const harness = createHarness();
  const engine = { id: "avplayer" };
  const resultPromise = harness.controller.transition(
    transitionOptions(harness, {
      engine,
      loadEngine: async ({ engine: created }) => {
        harness.calls.push(`load:${created.id}`);
        await loading.promise;
      },
    }),
  );

  while (!harness.calls.includes("load:avplayer")) await Promise.resolve();
  harness.setCurrentSession(99);
  loading.resolve();

  assert.equal(await resultPromise, false);
  assert.deepEqual(harness.destroyed, [engine]);
  assert.equal(harness.calls.filter((call) => call === "rollback:avplayer").length, 1);
  assert.equal(
    harness.calls.some((call) => call === "activate:avplayer"),
    false,
  );
});

test("cancel invalidates pending work and cleans a provisional engine", async () => {
  const restoring = deferred();
  const harness = createHarness();
  const engine = { id: "avplayer" };
  const cancelled = [];
  const resultPromise = harness.controller.transition(
    transitionOptions(harness, {
      engine,
      restoreEngine: async ({ engine: created }) => {
        harness.calls.push(`restore:${created.id}`);
        await restoring.promise;
      },
      onCancel(_context, reason) {
        cancelled.push(reason);
      },
    }),
  );

  while (!harness.calls.includes("restore:avplayer")) await Promise.resolve();
  assert.equal(await harness.controller.cancel("navigation"), true);
  restoring.resolve();

  assert.equal(await resultPromise, false);
  assert.deepEqual(cancelled, ["navigation"]);
  assert.deepEqual(harness.destroyed, [engine]);
  assert.equal(harness.calls.filter((call) => call === "destroy:avplayer").length, 1);
});

test("a cancelled pending rejection remains cancelled instead of becoming a failure", async () => {
  const loading = deferred();
  const harness = createHarness();
  const failures = [];
  const resultPromise = harness.controller.transition(
    transitionOptions(harness, {
      loadEngine: () => loading.promise,
      onFailure(error) {
        failures.push(error);
      },
    }),
  );

  while (harness.controller.snapshot().phase !== PLAYBACK_ENGINE_TRANSITION_PHASE.LOADING) {
    await Promise.resolve();
  }

  assert.equal(await harness.controller.cancel("navigation"), true);
  loading.reject(new Error("request aborted"));

  assert.equal(await resultPromise, false);
  assert.deepEqual(failures, []);
  assert.equal(
    harness.errors.some(({ operation }) => operation === "transition"),
    false,
  );
  assert.ok(
    harness.snapshots.some(({ phase }) => phase === PLAYBACK_ENGINE_TRANSITION_PHASE.CANCELLED),
  );
});

test("validates recovery boundaries before starting work", () => {
  const harness = createHarness({ currentSession: 7 });

  assert.throws(
    () => harness.controller.recover({ sourceSessionId: 7 }),
    /requires activateNative\(\)/,
  );
  assert.throws(
    () => harness.controller.recover({ activateNative() {} }),
    /requires sourceSessionId/,
  );
});

test("runs AVPlayer-to-native recovery after serialized source teardown", async () => {
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };

  const result = await harness.controller.recover(recoveryOptions(harness, { engine }));

  assert.equal(result, 8);
  assert.deepEqual(harness.calls, [
    "capture-recovery",
    "prepare-recovery:7",
    "release-recovery:7",
    "destroy:avplayer",
    "drain:null",
    "begin",
    "restore-native:8:24",
    "activate-native:8",
    "complete-recovery:8",
  ]);
  assert.deepEqual(harness.destroyed, [engine]);
});

test("deduplicates repeated runtime recovery for the same failed session", async () => {
  const restoring = deferred();
  const harness = createHarness({ currentSession: 7 });
  const options = recoveryOptions(harness, {
    restoreNative: async ({ sessionId }) => {
      harness.calls.push(`restore-native:${sessionId}`);
      await restoring.promise;
    },
  });

  const first = harness.controller.recover(options);
  const second = harness.controller.recover(options);
  assert.strictEqual(first, second);

  while (!harness.calls.includes("restore-native:8")) await Promise.resolve();
  restoring.resolve();
  assert.equal(await first, 8);
  assert.equal(harness.calls.filter((call) => call === "capture-recovery").length, 1);
  assert.equal(harness.calls.filter((call) => call === "destroy:avplayer").length, 1);
});

test("rejects recovery for a playback session that is already stale", async () => {
  const harness = createHarness({ currentSession: 8 });

  assert.equal(await harness.controller.recover(recoveryOptions(harness)), false);
  assert.deepEqual(harness.calls, []);
  assert.deepEqual(harness.destroyed, []);
});

test("cancelling recovery cannot reactivate native playback later", async () => {
  const restoring = deferred();
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };
  const resultPromise = harness.controller.recover(
    recoveryOptions(harness, {
      engine,
      restoreNative: async ({ sessionId }) => {
        harness.calls.push(`restore-native:${sessionId}`);
        await restoring.promise;
      },
    }),
  );

  while (!harness.calls.includes("restore-native:8")) await Promise.resolve();
  assert.equal(await harness.controller.cancel("navigation"), true);
  restoring.resolve();

  assert.equal(await resultPromise, false);
  assert.equal(
    harness.calls.some((call) => call === "activate-native:8"),
    false,
  );
  assert.equal(harness.calls.filter((call) => call === "destroy:avplayer").length, 1);
});

test("recovery destroys the failed engine before invoking product failure policy", async () => {
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };
  const original = new Error("native surface failed");
  const failures = [];

  const result = await harness.controller.recover(
    recoveryOptions(harness, {
      engine,
      restoreNative() {
        throw original;
      },
      onFailure(error, context) {
        failures.push({
          destroyedBeforeFailure: harness.destroyed.includes(engine),
          error,
          sessionId: context.sessionId,
          sourceSessionId: context.sourceSessionId,
        });
      },
    }),
  );

  assert.equal(result, false);
  assert.deepEqual(failures, [
    {
      destroyedBeforeFailure: true,
      error: original,
      sessionId: 8,
      sourceSessionId: 7,
    },
  ]);
  assert.equal(harness.errors.at(-1).operation, "recovery");
  assert.strictEqual(harness.errors.at(-1).error, original);
});

test("recovery teardown failure blocks native activation and preserves the source error", async () => {
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };
  const original = new Error("failed to release AVPlayer");
  const failures = [];

  const result = await harness.controller.recover(
    recoveryOptions(harness, {
      engine,
      releasePrevious({ sourceSessionId }) {
        harness.calls.push(`release-recovery:${sourceSessionId}`);
        throw original;
      },
      onFailure(error, context) {
        failures.push({
          error,
          sessionId: context.sessionId,
          sourceSessionId: context.sourceSessionId,
        });
      },
    }),
  );

  assert.equal(result, false);
  assert.deepEqual(harness.calls, [
    "capture-recovery",
    "prepare-recovery:7",
    "release-recovery:7",
    "destroy:avplayer",
    "drain:null",
  ]);
  assert.deepEqual(harness.destroyed, [engine]);
  assert.deepEqual(failures, [
    {
      error: original,
      sessionId: null,
      sourceSessionId: 7,
    },
  ]);
  assert.equal(harness.errors.at(-2).operation, "release_previous");
  assert.strictEqual(harness.errors.at(-2).error, original);
  assert.equal(harness.errors.at(-1).operation, "recovery");
  assert.strictEqual(harness.errors.at(-1).error, original);
  assert.equal(harness.calls.includes("begin"), false);
  assert.equal(
    harness.calls.some((call) => call.startsWith("restore-native:")),
    false,
  );
  assert.equal(
    harness.calls.some((call) => call.startsWith("activate-native:")),
    false,
  );
});

test("routes the original transition error through one failure outcome", async () => {
  const harness = createHarness();
  const engine = { id: "avplayer" };
  const original = new Error("decoder failed");
  const failures = [];

  const result = await harness.controller.transition(
    transitionOptions(harness, {
      engine,
      loadEngine() {
        throw original;
      },
      async onFailure(error, context) {
        failures.push({
          destroyedBeforeFailure: harness.destroyed.includes(engine),
          error,
          engine: context.engine,
          sessionId: context.sessionId,
        });
      },
    }),
  );

  assert.equal(result, false);
  assert.deepEqual(failures, [
    {
      destroyedBeforeFailure: true,
      error: original,
      engine,
      sessionId: 1,
    },
  ]);
  assert.deepEqual(harness.destroyed, [engine]);
  assert.equal(harness.errors.at(-1).operation, "transition");
  assert.strictEqual(harness.errors.at(-1).error, original);
});

test("failure-handler and diagnostic errors cannot replace the transition error", async () => {
  const original = new Error("load failed");
  const diagnostic = new Error("diagnostic failed");
  const harness = createHarness({
    onError() {
      throw diagnostic;
    },
  });

  const result = await harness.controller.transition(
    transitionOptions(harness, {
      loadEngine() {
        throw original;
      },
      onFailure() {
        throw new Error("failure handler failed");
      },
    }),
  );

  assert.equal(result, false);
  assert.equal(harness.errors[0].operation, "failure_handler");
  assert.equal(harness.errors.at(-1).operation, "transition");
  assert.strictEqual(harness.errors.at(-1).error, original);
});

test("does not destroy an engine after the transition commits", async () => {
  const harness = createHarness();
  const engine = { id: "avplayer" };

  await harness.controller.transition(transitionOptions(harness, { engine }));
  assert.equal(await harness.controller.cancel("too late"), false);
  assert.equal(harness.controller.destroy(), true);
  assert.deepEqual(harness.destroyed, []);
});

test("destroy is terminal, idempotent and cleans active provisional work", async () => {
  const loading = deferred();
  const harness = createHarness();
  const engine = { id: "avplayer" };
  const resultPromise = harness.controller.transition(
    transitionOptions(harness, {
      engine,
      loadEngine: async () => loading.promise,
    }),
  );

  while (harness.controller.snapshot().phase !== PLAYBACK_ENGINE_TRANSITION_PHASE.LOADING) {
    await Promise.resolve();
  }

  assert.equal(harness.controller.destroy(), true);
  assert.equal(harness.controller.destroy(), false);
  loading.resolve();
  assert.equal(await resultPromise, false);
  assert.deepEqual(harness.destroyed, [engine]);
  assert.equal(harness.controller.destroyed, true);
  assert.equal(harness.controller.snapshot().phase, PLAYBACK_ENGINE_TRANSITION_PHASE.DESTROYED);
  assert.equal(await harness.controller.transition(transitionOptions(harness)), false);
});

test("queues recovery requested during the forward transition commit window", async () => {
  let harness;
  let recoveryPromise = null;
  let recoveryRequested = false;
  const failedEngine = { id: "failed-avplayer" };

  harness = createHarness({
    onStateChange(snapshot) {
      if (!recoveryRequested && snapshot.phase === PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETED) {
        recoveryRequested = true;
        recoveryPromise = harness.controller.recover(
          recoveryOptions(harness, {
            engine: failedEngine,
            sourceSessionId: 1,
          }),
        );
      }
    },
  });

  const forwardEngine = await harness.controller.transition(transitionOptions(harness));
  assert.equal(forwardEngine.id, "avplayer");
  assert.ok(recoveryPromise);
  assert.equal(await recoveryPromise, 2);
  assert.equal(harness.calls.filter((call) => call === "begin").length, 2);
  assert.equal(harness.calls.filter((call) => call === "destroy:failed-avplayer").length, 1);
});

test("transition-specific destroyer overrides the global provisional-engine destroyer", async () => {
  const harness = createHarness();
  const engine = { id: "mpegts" };
  const locallyDestroyed = [];
  const original = new Error("load failed");

  const result = await harness.controller.transition(
    transitionOptions(harness, {
      engine,
      destroyEngine(created, context) {
        locallyDestroyed.push({ created, key: context.key });
      },
      loadEngine() {
        throw original;
      },
    }),
  );

  assert.equal(result, false);
  assert.deepEqual(locallyDestroyed, [{ created: engine, key: "native-to-avplayer" }]);
  assert.deepEqual(harness.destroyed, []);
});

test("recovery-specific destroyer overrides the global source-engine destroyer", async () => {
  const harness = createHarness({ currentSession: 7 });
  const engine = { id: "avplayer" };
  const locallyDestroyed = [];

  const result = await harness.controller.recover(
    recoveryOptions(harness, {
      engine,
      sourceSessionId: 7,
      destroyEngine(created, context) {
        locallyDestroyed.push({ created, key: context.key });
      },
    }),
  );

  assert.equal(result, 8);
  assert.equal(locallyDestroyed.length, 1);
  assert.strictEqual(locallyDestroyed[0].created, engine);
  assert.equal(typeof locallyDestroyed[0].key, "string");
  assert.deepEqual(harness.destroyed, []);
});
