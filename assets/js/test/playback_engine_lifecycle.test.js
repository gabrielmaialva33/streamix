import assert from "node:assert/strict";
import test from "node:test";

import { stopThenDestroyPlaybackEngine } from "../player/playback_engine_lifecycle.js";

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
