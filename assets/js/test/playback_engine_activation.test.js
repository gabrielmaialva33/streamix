import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_SELECTION } from "../player/engine_contract.js";
import {
  assertActivationHost,
  createPlaybackEngineActivation,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "../player/playback_engine_activation.js";

function createHost(overrides = {}) {
  return {
    getCurrentUrl: () => "https://example.test/stream.m3u8",
    getSessionId: () => 7,
    isSessionCurrent: (sessionId) => sessionId === 7,
    ...overrides,
  };
}

test("assertActivationHost lists every missing host member", () => {
  assert.throws(
    () => assertActivationHost({ getSessionId() {} }, PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS),
    /host is missing: getCurrentUrl, isSessionCurrent/,
  );
  assert.throws(() => assertActivationHost(null, []), /requires an activation host/);
});

test("activate dispatches the selection with a session-scoped request", async () => {
  const requests = [];
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.HLS_JS]: {
        activate(request) {
          requests.push(request);
          return "hls";
        },
      },
    },
  });

  const result = await activation.activate(ENGINE_SELECTION.HLS_JS);

  assert.equal(result, "hls");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].selection, ENGINE_SELECTION.HLS_JS);
  assert.equal(requests[0].requestedSelection, ENGINE_SELECTION.HLS_JS);
  assert.equal(requests[0].engineId, "hls");
  assert.equal(requests[0].sessionId, 7);
  assert.equal(requests[0].url, "https://example.test/stream.m3u8");
  assert.equal(typeof requests[0].activate, "function");
  assert.ok(Object.isFrozen(requests[0]));
});

test("function activations resolve undefined to true and keep extra request fields", async () => {
  const seen = [];
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.NATIVE]: (request) => {
        seen.push(request);
      },
    },
  });

  assert.equal(
    await activation.activate(ENGINE_SELECTION.NATIVE, { sessionId: 7, reason: "x" }),
    true,
  );
  assert.equal(seen[0].reason, "x");
  assert.equal(seen[0].sessionId, 7);
});

test("unknown selections report and fall back to the configured selection", async () => {
  const unknown = [];
  const activated = [];
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.NATIVE]: (request) => {
        activated.push(request.selection);
      },
    },
    onUnknownSelection: (selection) => unknown.push(selection),
  });

  assert.equal(await activation.activate("webrtc"), true);
  assert.deepEqual(unknown, ["webrtc"]);
  assert.deepEqual(activated, [ENGINE_SELECTION.NATIVE]);
  assert.equal(activation.snapshot().selection, ENGINE_SELECTION.NATIVE);
});

test("unknown selection without a fallback resolves false", async () => {
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: { [ENGINE_SELECTION.HLS_JS]: () => true },
  });

  assert.equal(await activation.activate(ENGINE_SELECTION.AVPLAYER), false);
});

test("stale sessions are rejected before any activation runs", async () => {
  let ran = 0;
  const activation = createPlaybackEngineActivation({
    host: createHost({ isSessionCurrent: (sessionId) => sessionId === 7 }),
    activations: {
      [ENGINE_SELECTION.NATIVE]: () => {
        ran += 1;
      },
    },
  });

  assert.equal(await activation.activate(ENGINE_SELECTION.NATIVE, { sessionId: 6 }), false);
  assert.equal(ran, 0);
});

test("synchronous and asynchronous activation failures become false plus onError", async () => {
  const errors = [];
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.HLS_JS]: () => {
        throw new Error("sync boom");
      },
      [ENGINE_SELECTION.MPEGTS]: async () => {
        throw new Error("async boom");
      },
    },
    onError: (operation, error, request) =>
      errors.push([operation, error.message, request.selection]),
  });

  assert.equal(await activation.activate(ENGINE_SELECTION.HLS_JS), false);
  assert.equal(await activation.activate(ENGINE_SELECTION.MPEGTS), false);
  assert.deepEqual(errors, [
    ["activate", "sync boom", ENGINE_SELECTION.HLS_JS],
    ["activate", "async boom", ENGINE_SELECTION.MPEGTS],
  ]);
  assert.equal(activation.snapshot().pending, 0);
});

test("pending activations are visible in the snapshot until they settle", async () => {
  const snapshots = [];
  let release;
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.NATIVE]: () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    },
    onStateChange: (snapshot) => snapshots.push(snapshot),
  });

  const outcome = activation.activate(ENGINE_SELECTION.NATIVE);
  assert.equal(activation.active, true);
  assert.equal(activation.snapshot().pending, 1);

  release(true);
  assert.equal(await outcome, true);
  assert.equal(activation.active, false);
  assert.deepEqual(
    snapshots.map((snapshot) => snapshot.pending),
    [1, 0],
  );
});

test("activations can chain into other selections through the request", async () => {
  const order = [];
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: {
      [ENGINE_SELECTION.HLS_JS]: (request) => {
        order.push("hls");
        return request.activate(ENGINE_SELECTION.NATIVE, { sessionId: request.sessionId });
      },
      [ENGINE_SELECTION.NATIVE]: () => {
        order.push("native");
        return "native-result";
      },
    },
  });

  assert.equal(await activation.activate(ENGINE_SELECTION.HLS_JS), "native-result");
  assert.deepEqual(order, ["hls", "native"]);
});

test("register validates selections and activation shapes", () => {
  const activation = createPlaybackEngineActivation({ host: createHost() });

  assert.throws(() => activation.register("dash", () => true), /Unknown playback engine selection/);
  assert.throws(
    () => activation.register(ENGINE_SELECTION.NATIVE, { start() {} }),
    /must expose activate\(\)/,
  );
  assert.equal(activation.has(ENGINE_SELECTION.NATIVE), false);

  activation.register(ENGINE_SELECTION.NATIVE, () => true);
  assert.equal(activation.has(ENGINE_SELECTION.NATIVE), true);
  assert.equal(typeof activation.get(ENGINE_SELECTION.NATIVE).activate, "function");
  assert.deepEqual(activation.selections(), [ENGINE_SELECTION.NATIVE]);
});

test("destroy clears activations and rejects further work", async () => {
  const activation = createPlaybackEngineActivation({
    host: createHost(),
    activations: { [ENGINE_SELECTION.NATIVE]: () => true },
  });

  assert.equal(activation.destroy(), true);
  assert.equal(activation.destroy(), false);
  assert.equal(activation.get(ENGINE_SELECTION.NATIVE), null);
  assert.equal(activation.has(ENGINE_SELECTION.NATIVE), false);
  assert.equal(await activation.activate(ENGINE_SELECTION.NATIVE), false);
  assert.throws(() => activation.register(ENGINE_SELECTION.NATIVE, () => true), /destroyed/);
  assert.equal(activation.snapshot().destroyed, true);
});
