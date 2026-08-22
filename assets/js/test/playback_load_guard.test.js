import assert from "node:assert/strict";
import test from "node:test";

import {
  guardPlaybackLoad,
  runGuardedPlaybackRetry,
  scheduleGuardedPlaybackRetry,
} from "../player/playback_load_guard.js";

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

test("contains lazy-load rejection for a fire-and-forget caller", async () => {
  const error = new Error("manifest failed synchronously");
  const result = await guardPlaybackLoad({
    load: () => {
      throw error;
    },
  });

  assert.deepEqual(result, { engine: null, error, status: "error" });
});

test("a scheduled retry from an old session never touches the replacement loader", async () => {
  let scheduled;
  let current = true;
  const calls = [];
  const loaderA = { load: () => calls.push("loader-a") };
  const loaderB = { load: () => calls.push("loader-b") };

  scheduleGuardedPlaybackRetry({
    delayMs: 1_000,
    isCurrent: () => current,
    run: () => loaderA.load(),
    schedule: (callback) => {
      scheduled = callback;
      return 42;
    },
  });

  current = false;
  scheduled();
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(calls, []);
  assert.notEqual(loaderA, loaderB);
});

test("a rejected fire-and-forget retry is contained and reported once", async () => {
  const error = new Error("soft reload failed");
  const errors = [];

  assert.equal(
    await runGuardedPlaybackRetry({
      run: () => Promise.reject(error),
      onError: (caught) => errors.push(caught),
    }),
    false,
  );
  assert.deepEqual(errors, [error]);
});

test("destroys an engine whose playback session became stale during import", async () => {
  const importGate = deferred();
  const engine = { name: "stale" };
  let current = true;
  const destroyed = [];
  const loading = guardPlaybackLoad({
    load: () => importGate.promise,
    isCurrent: () => current,
    destroy: (loadedEngine) => destroyed.push(loadedEngine),
  });

  current = false;
  importGate.resolve(engine);

  assert.deepEqual(await loading, { engine: null, status: "stale" });
  assert.deepEqual(destroyed, [engine]);
});
