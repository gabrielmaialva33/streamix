import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_ID, ENGINE_SELECTION } from "../player/engine_contract.js";
import {
  createHlsEngineActivation,
  HLS_ENGINE_ACTIVATION_HOST_METHODS,
  HLS_UNSUPPORTED_MESSAGE,
} from "../player/hls_engine_activation.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

class CancelledError extends Error {
  constructor() {
    super("cancelled");
    this.name = "StreamLoaderCancelledError";
  }
}

function createLoader({
  loadHls,
  hlsEngine = { client: { id: "hls-client" }, destroyed: false },
} = {}) {
  const loader = {
    destroyed: 0,
    hlsEngine,
    loadHls: loadHls ?? (async () => loader.hlsEngine.client),
    getHlsEngine: () => loader.hlsEngine,
    destroy: async () => {
      loader.destroyed += 1;
    },
  };
  return loader;
}

function createHarness({ hostOverrides = {}, dependencies = {}, loader = createLoader() } = {}) {
  const calls = {
    activated: [],
    errors: [],
    hlsClients: [],
    lifecycle: [],
    registered: [],
    recordedErrors: 0,
    suppressed: [],
    syncedPiP: 0,
    teardownSessions: [],
  };
  const state = { sessionId: 3, loader, nativeHls: false, canPlayNative: "" };
  const host = {
    ensureStreamLoader: () => state.loader,
    getCurrentUrl: () => "https://example.test/live.m3u8",
    getNativeHlsSupport: () => state.nativeHls,
    getSessionId: () => state.sessionId,
    getStreamLoader: () => state.loader,
    getVideo: () => ({ canPlayType: () => state.canPlayNative }),
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    recordPlaybackError: () => {
      calls.recordedErrors += 1;
    },
    registerMediaElementEngine: (engineId, engine) => {
      calls.registered.push([engineId, engine]);
      return { id: engineId, engine };
    },
    reportLifecycle: (stage, extra) => calls.lifecycle.push([stage, extra]),
    setHlsClient: (client) => calls.hlsClients.push(client),
    setNativePlaybackEventsSuppressed: (value) => calls.suppressed.push(value),
    showPlaybackError: (message) => calls.errors.push(message),
    syncPiPAvailability: () => {
      calls.syncedPiP += 1;
    },
    teardownStreamLoaderForTransition: async (sessionId) => {
      calls.teardownSessions.push(sessionId);
      state.sessionId += 1;
      return state.sessionId;
    },
    ...hostOverrides,
  };
  const activation = createHlsEngineActivation({
    host,
    logger: silentLogger,
    dependencies: {
      isHlsJsSupported: () => true,
      isStreamLoaderCancelledError: (error) => error instanceof CancelledError,
      ...dependencies,
    },
  });
  const request = (overrides = {}) => ({
    activate: (selection, options) => {
      calls.activated.push([selection, options]);
      return "chained";
    },
    engineId: ENGINE_ID.HLS,
    selection: ENGINE_SELECTION.HLS_JS,
    sessionId: state.sessionId,
    url: host.getCurrentUrl(),
    ...overrides,
  });

  return { activation, calls, host, request, state };
}

test("the activation validates its host contract up front", () => {
  assert.throws(
    () => createHlsEngineActivation({ host: {} }),
    /HlsEngineActivation host is missing/,
  );
  assert.ok(HLS_ENGINE_ACTIVATION_HOST_METHODS.includes("registerMediaElementEngine"));
});

test("a successful load borrows the loader engine into the media element registry", async () => {
  const { activation, calls, request, state } = createHarness();

  assert.equal(await activation.activate(request()), true);
  assert.deepEqual(calls.suppressed, [false]);
  assert.equal(calls.syncedPiP, 1);
  assert.deepEqual(calls.lifecycle, [["player_engine_selected", { engine: ENGINE_ID.HLS }]]);
  assert.deepEqual(calls.hlsClients, [
    state.loader.hlsEngine.client,
    state.loader.hlsEngine.client,
  ]);
  assert.deepEqual(calls.registered, [[ENGINE_ID.HLS, state.loader.hlsEngine]]);
  assert.equal(state.loader.destroyed, 0);
});

test("a loader that never exposes an engine is a programming error", async () => {
  const loader = createLoader({ hlsEngine: null, loadHls: async () => "client" });
  const { activation, request } = createHarness({ loader });

  await assert.rejects(activation.activate(request()), /was not registered by StreamLoader/);
});

test("without hls.js support native HLS takes over when the element can play it", async () => {
  const { activation, calls, request, state } = createHarness({
    dependencies: { isHlsJsSupported: () => false },
  });
  state.canPlayNative = "maybe";

  assert.equal(await activation.activate(request()), "chained");
  assert.deepEqual(calls.activated, [[ENGINE_SELECTION.NATIVE, { sessionId: 3 }]]);
  assert.deepEqual(calls.errors, []);
});

test("without any HLS support the user sees the unsupported message", async () => {
  const { activation, calls, request } = createHarness({
    dependencies: { isHlsJsSupported: () => false },
  });

  assert.equal(await activation.activate(request()), false);
  assert.deepEqual(calls.errors, [HLS_UNSUPPORTED_MESSAGE]);
  assert.deepEqual(calls.activated, []);
});

test("cancelled and stale loads end quietly", async () => {
  const cancelled = createHarness({
    loader: createLoader({
      loadHls: async () => {
        throw new CancelledError();
      },
    }),
  });
  assert.equal(await cancelled.activation.activate(cancelled.request()), false);
  assert.deepEqual(cancelled.calls.registered, []);
  assert.equal(cancelled.calls.recordedErrors, 0);

  const stale = createHarness();
  stale.state.loader.loadHls = async () => {
    stale.state.sessionId += 1;
    return "client";
  };
  assert.equal(await stale.activation.activate(stale.request({ sessionId: 3 })), false);
  assert.equal(stale.state.loader.destroyed, 1, "stale loads destroy the provisional loader");
  assert.deepEqual(stale.calls.registered, []);
});

test("load failures tear the transport down and fall back to native HLS when available", async () => {
  const { activation, calls, request, state } = createHarness({
    loader: createLoader({
      loadHls: async () => {
        throw new Error("manifest 500");
      },
    }),
  });
  state.nativeHls = true;

  assert.equal(await activation.activate(request()), "chained");
  assert.equal(calls.recordedErrors, 1);
  assert.deepEqual(calls.teardownSessions, [3]);
  assert.deepEqual(calls.activated, [[ENGINE_SELECTION.NATIVE, { sessionId: 4 }]]);
});

test("load failures without native HLS show the unsupported message", async () => {
  const { activation, calls, request } = createHarness({
    loader: createLoader({
      loadHls: async () => {
        throw new Error("manifest 500");
      },
    }),
  });

  assert.equal(await activation.activate(request()), false);
  assert.deepEqual(calls.errors, [HLS_UNSUPPORTED_MESSAGE]);
});

test("load failures on a superseded session do nothing further", async () => {
  const { activation, calls, request } = createHarness({
    hostOverrides: { teardownStreamLoaderForTransition: async () => null },
    loader: createLoader({
      loadHls: async () => {
        throw new Error("manifest 500");
      },
    }),
  });

  assert.equal(await activation.activate(request()), false);
  assert.deepEqual(calls.errors, []);
  assert.deepEqual(calls.activated, []);
});

test("adoptLoaderEngine guards session, loader identity and destroyed engines", () => {
  const { activation, calls, state } = createHarness();

  assert.equal(activation.adoptLoaderEngine(2), null, "stale session");
  assert.equal(activation.adoptLoaderEngine(3, createLoader()), null, "foreign loader");

  state.loader.hlsEngine = { client: {}, destroyed: true };
  assert.equal(activation.adoptLoaderEngine(3), null, "destroyed engine");

  state.loader.hlsEngine = { client: { id: "fresh" }, destroyed: false };
  const registered = activation.adoptLoaderEngine();
  assert.equal(registered.id, ENGINE_ID.HLS);
  assert.deepEqual(calls.hlsClients, [{ id: "fresh" }]);
  assert.deepEqual(calls.registered, [[ENGINE_ID.HLS, state.loader.hlsEngine]]);
});
