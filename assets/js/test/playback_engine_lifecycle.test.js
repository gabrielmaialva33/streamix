import assert from "node:assert/strict";
import test from "node:test";

import {
  awaitPlaybackOperation,
  createSynchronousErrorNotifier,
  PlaybackEngineTeardownQueue,
  resolvePlaybackResumeTime,
  stopThenDestroyPlaybackEngine,
} from "../player/playback_engine_lifecycle.js";

test("clears playback-operation timeouts on both success and failure", async () => {
  const cleared = [];
  let timeoutCalls = 0;
  const timerApi = {
    setTimeout() {
      timeoutCalls += 1;
      return timeoutCalls;
    },
    clearTimeout(id) {
      cleared.push(id);
    },
  };

  assert.equal(await awaitPlaybackOperation(Promise.resolve("ok"), { timerApi }), "ok");
  await assert.rejects(
    awaitPlaybackOperation(Promise.reject(new Error("load failed")), { timerApi }),
    /load failed/,
  );
  assert.equal(await awaitPlaybackOperation("sync", { timerApi }), "sync");

  assert.equal(timeoutCalls, 2);
  assert.deepEqual(cleared, [1, 2]);
});

test("rejects a stuck playback operation once and clears its timeout", async () => {
  const cleared = [];
  const timerApi = {
    setTimeout(callback) {
      queueMicrotask(callback);
      return 9;
    },
    clearTimeout(id) {
      cleared.push(id);
    },
  };

  await assert.rejects(
    awaitPlaybackOperation(new Promise(() => {}), {
      timeoutMs: 1,
      timerApi,
      timeoutMessage: "load timed out",
    }),
    /load timed out/,
  );
  assert.deepEqual(cleared, [9]);
});

test("deduplicates the same synchronously reported playback error", async () => {
  const reports = [];
  let resetReportedErrors;
  const notify = createSynchronousErrorNotifier(
    (error) => reports.push(error),
    (reset) => {
      resetReportedErrors = reset;
    },
  );
  const error = new Error("synchronous load failure");

  assert.equal(notify(error), true);
  assert.equal(notify(error), false);
  await Promise.resolve();
  assert.equal(notify(error), false);
  resetReportedErrors();
  assert.equal(notify(error), true);
  assert.deepEqual(reports, [error, error]);
});

test("serializes engine teardown and deduplicates an in-flight engine", async () => {
  const calls = [];
  let releaseFirst;
  const firstDone = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const first = {
    async destroy() {
      calls.push("first:start");
      await firstDone;
      calls.push("first:end");
    },
  };
  const second = {
    destroy() {
      calls.push("second");
    },
  };
  const queue = new PlaybackEngineTeardownQueue();

  const firstTeardown = queue.destroy(first);
  assert.equal(queue.destroy(first), firstTeardown);
  const secondTeardown = queue.destroy(second);
  await Promise.resolve();
  assert.deepEqual(calls, ["first:start"]);

  releaseFirst();
  await Promise.all([firstTeardown, secondTeardown, queue.drain()]);
  assert.deepEqual(calls, ["first:start", "first:end", "second"]);
});

test("stops playback before destroying its engine", async () => {
  const calls = [];
  const player = {
    async stop() {
      calls.push("stop");
    },
    async destroy() {
      calls.push("destroy");
    },
  };

  await stopThenDestroyPlaybackEngine(player);

  assert.deepEqual(calls, ["stop", "destroy"]);
});

test("invokes stop synchronously and still destroys after a stuck stop", async () => {
  const calls = [];
  const errors = [];
  const timerApi = {
    setTimeout(callback) {
      queueMicrotask(callback);
      return 7;
    },
    clearTimeout() {},
  };
  const player = {
    stop() {
      calls.push("stop");
      return new Promise(() => {});
    },
    destroy() {
      calls.push("destroy");
    },
  };

  const teardown = stopThenDestroyPlaybackEngine(player, {
    timeoutMs: 1,
    timerApi,
    onError: (operation) => errors.push(operation),
  });

  assert.deepEqual(calls, ["stop"]);
  await teardown;

  assert.deepEqual(calls, ["stop", "destroy"]);
  assert.deepEqual(errors, ["stop"]);
});

test("late engine errors resume from current playback time before the initial fallback", () => {
  assert.equal(resolvePlaybackResumeTime({ getCurrentTime: () => 87.5 }, 12), 87.5);
  assert.equal(resolvePlaybackResumeTime({ getCurrentTime: () => 0 }, 12), 12);
  assert.equal(
    resolvePlaybackResumeTime(
      {
        getCurrentTime() {
          throw new Error("disposed");
        },
      },
      12,
    ),
    12,
  );
});
