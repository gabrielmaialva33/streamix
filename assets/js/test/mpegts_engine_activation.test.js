import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_ID, ENGINE_SELECTION } from "../player/engine_contract.js";
import {
  createMpegtsEngineActivation,
  FLV_UNSUPPORTED_MESSAGE,
  MPEGTS_ENGINE_ACTIVATION_HOST_METHODS,
} from "../player/mpegts_engine_activation.js";
import { createPlaybackEngineTransitionController } from "../player/playback_engine_transition_controller.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

class CancelledError extends Error {
  constructor() {
    super("cancelled");
    this.name = "StreamLoaderCancelledError";
  }
}

function createLoader({ loadMpegts } = {}) {
  const loader = {
    destroyed: 0,
    engine: null,
    player: null,
    loads: [],
    loadMpegts:
      loadMpegts ??
      (async (url, type) => {
        loader.loads.push([url, type]);
        loader.player = { type };
        loader.engine = { id: `mpegts-${type}`, destroy: async () => {} };
        return loader.player;
      }),
    getMpegtsEngine: () => loader.engine,
    getMpegtsPlayer: () => loader.player,
    destroy: async () => {
      loader.destroyed += 1;
      loader.engine = null;
      loader.player = null;
    },
  };
  return loader;
}

function createHarness({ hostOverrides = {}, loader = createLoader() } = {}) {
  const calls = {
    cleared: [],
    debug: [],
    errors: [],
    lifecycle: [],
    playAfterResume: [],
    presentation: [],
    recovered: 0,
    recoveries: [],
    recordedErrors: 0,
    registered: [],
    released: [],
    suppressed: [],
    syncedPiP: 0,
    teardownSessions: [],
  };
  const state = { sessionId: 5, loader, mpegtsPlayer: null };
  const video = new EventTarget();
  const controller = createPlaybackEngineTransitionController({
    beginSession: () => {
      state.sessionId += 1;
      return state.sessionId;
    },
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    drainTeardown: async () => {},
    destroyEngine: async () => {
      throw new Error("default destroyer must not be used for MPEG-TS");
    },
  });
  const host = {
    clearStreamLoader: (candidate) => {
      calls.cleared.push(candidate);
      if (state.loader === candidate) state.loader = null;
    },
    ensureStreamLoader: () => {
      state.loader ??= createLoader();
      return state.loader;
    },
    getCurrentUrl: () => "https://example.test/live.ts",
    getMpegtsPlayer: () => state.mpegtsPlayer,
    getPresentation: () => ({
      hideLoading: () => calls.presentation.push("hideLoading"),
      hideError: () => calls.presentation.push("hideError"),
    }),
    getSessionId: () => state.sessionId,
    getStreamLoader: () => state.loader,
    getTransitionController: () => controller,
    getVideo: () => video,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    markMpegtsRecovered: () => {
      calls.recovered += 1;
    },
    playNativeAfterResume: async (sessionId) => {
      calls.playAfterResume.push(sessionId);
    },
    recordPlaybackError: () => {
      calls.recordedErrors += 1;
    },
    recoverFromMpegtsError: (data) => {
      calls.recoveries.push(data);
      return "recovering";
    },
    registerMediaElementEngine: (engineId, engine) => {
      calls.registered.push([engineId, engine]);
      return { id: engineId, engine };
    },
    releaseEngine: (engineId) => calls.released.push(engineId),
    reportDebug: (stage, extra) => calls.debug.push([stage, extra]),
    reportLifecycle: (stage, extra) => calls.lifecycle.push([stage, extra]),
    setMpegtsPlayer: (player) => {
      state.mpegtsPlayer = player;
    },
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
  const activation = createMpegtsEngineActivation({
    host,
    logger: silentLogger,
    dependencies: { isStreamLoaderCancelledError: (error) => error instanceof CancelledError },
  });
  const request = (selection = ENGINE_SELECTION.MPEGTS, overrides = {}) => ({
    activate: () => {
      throw new Error("MPEG-TS activation must not chain");
    },
    engineId: ENGINE_ID.MPEGTS,
    selection,
    sessionId: state.sessionId,
    url: host.getCurrentUrl(),
    ...overrides,
  });

  return { activation, calls, controller, host, request, state, video };
}

test("the activation validates its host contract up front", () => {
  assert.throws(
    () => createMpegtsEngineActivation({ host: {} }),
    /MpegtsEngineActivation host is missing/,
  );
  assert.ok(MPEGTS_ENGINE_ACTIVATION_HOST_METHODS.includes("getTransitionController"));
});

test("a successful startup borrows the loader engine and requests native playback", async () => {
  const { activation, calls, request, state, video } = createHarness();

  const result = await activation.activate(request());

  assert.equal(result, state.loader.engine);
  assert.deepEqual(state.loader.loads, [["https://example.test/live.ts", "mpegts"]]);
  assert.deepEqual(calls.registered, [[ENGINE_ID.MPEGTS, state.loader.engine]]);
  assert.equal(state.mpegtsPlayer, state.loader.player);
  assert.deepEqual(calls.playAfterResume, [5]);
  assert.deepEqual(calls.suppressed, [false]);
  assert.equal(calls.syncedPiP, 1);
  assert.deepEqual(calls.debug, [["play_with_mpegts", { requested_type: "mpegts" }]]);
  assert.deepEqual(calls.lifecycle, [
    [
      "player_engine_selected",
      { engine: ENGINE_ID.MPEGTS, requested_type: "mpegts", session_id: 5 },
    ],
  ]);
  assert.equal(state.loader.destroyed, 0);

  video.dispatchEvent(new Event("playing"));
  assert.equal(calls.recovered, 1);
  assert.deepEqual(calls.presentation, ["hideLoading", "hideError"]);
});

test("the FLV selection loads with the flv type", async () => {
  const { activation, request, state } = createHarness();

  await activation.activate(request(ENGINE_SELECTION.MPEGTS_FLV));

  assert.deepEqual(state.loader.loads, [["https://example.test/live.ts", "flv"]]);
});

test("load failures roll back the provisional transport and enter MPEG-TS recovery", async () => {
  const failure = new Error("transport down");
  const loader = createLoader({
    loadMpegts: async () => {
      throw failure;
    },
  });
  const { activation, calls, request, state } = createHarness({ loader });

  assert.equal(await activation.activate(request()), false);
  assert.equal(calls.recordedErrors, 1);
  assert.deepEqual(calls.released, [ENGINE_ID.MPEGTS]);
  assert.equal(loader.destroyed, 1);
  assert.deepEqual(calls.cleared, [loader]);
  assert.equal(state.loader, null);
  assert.deepEqual(calls.recoveries, [
    { errorType: "OtherError", errorDetail: "OtherError", errorInfo: { cause: failure } },
  ]);
  assert.deepEqual(calls.errors, []);
});

test("FLV failures tear the loader down and report the unsupported message", async () => {
  const loader = createLoader({
    loadMpegts: async () => {
      throw new Error("flv unsupported");
    },
  });
  const { activation, calls, request } = createHarness({ loader });

  assert.equal(await activation.activate(request(ENGINE_SELECTION.MPEGTS_FLV)), false);
  assert.deepEqual(calls.teardownSessions, [5]);
  assert.deepEqual(calls.errors, [FLV_UNSUPPORTED_MESSAGE]);
  assert.deepEqual(calls.recoveries, []);
});

test("a session superseded during the load ends without recovery or registration", async () => {
  const harness = createHarness();
  harness.state.loader.loadMpegts = async () => {
    harness.state.sessionId += 1;
    return {};
  };

  assert.equal(await harness.activation.activate(harness.request()), false);
  assert.deepEqual(harness.calls.registered, []);
  assert.deepEqual(harness.calls.recoveries, []);
  assert.deepEqual(harness.calls.playAfterResume, []);

  harness.video.dispatchEvent(new Event("playing"));
  assert.equal(harness.calls.recovered, 0, "the once listener is removed on stale loads");
});

test("cancelled loads surface as transition failures without the unsupported message", async () => {
  const loader = createLoader({
    loadMpegts: async () => {
      throw new CancelledError();
    },
  });
  const { activation, calls, request } = createHarness({ loader });

  assert.equal(await activation.activate(request()), false);
  assert.equal(calls.recordedErrors, 0);
  assert.deepEqual(calls.errors, []);
});

test("without a transition controller the activation resolves false", async () => {
  const { activation, request } = createHarness({
    hostOverrides: { getTransitionController: () => null },
  });

  assert.equal(await activation.activate(request()), false);
});
