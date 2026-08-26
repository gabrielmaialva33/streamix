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
