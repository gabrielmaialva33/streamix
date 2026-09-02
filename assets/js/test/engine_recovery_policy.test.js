import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_STATE } from "../player/engine_contract.js";
import {
  createEngineRecoveryPolicy,
  ENGINE_RECOVERY_HOST_METHODS,
  ENGINE_RECOVERY_TELEMETRY_DEPENDENCIES,
} from "../player/engine_recovery_policy.js";
import {
  HLS_RECOVERY_OPERATION,
  HLS_RECOVERY_OUTCOME,
  HLS_RECOVERY_REASON,
} from "../player/hls_recovery_coordinator.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createHarness({ state: overrides = {}, dependencies: depOverrides = {} } = {}) {
  const calls = {
    cleanups: [],
    direct: 0,
    errors: [],
    hls: [],
    mpegts: [],
    observed: [],
    playbackErrors: [],
    plays: [],
    pushes: [],
    records: 0,
    retries: 0,
    teardowns: [],
  };
  const state = {
    canRetry: true,
    canTryAVPlayer: false,
    decision: { outcome: HLS_RECOVERY_OUTCOME.IGNORED, event: { details: "minor" } },
    directAllowed: true,
    mpegtsSupported: true,
    nextSessionId: 4,
    protocol: "https:",
    sessionId: 3,
    urls: {
      currentUrl: "https://proxy/live.ts",
      streamUrl: "http://direct/live.ts",
      useProxy: true,
    },
    ...overrides,
  };
  const hls = {
    handle: (data, context) => {
      calls.hls.push([data, context]);
      return { decision: state.decision };
    },
  };
  const mpegts = {
    handle: (data, actions) => {
      calls.mpegts.push({ data, actions });
      return Promise.resolve("handled");
    },
  };
  const host = {
    canRetry: () => state.canRetry,
    canTryAVPlayer: () => state.canTryAVPlayer,
    cleanup: (options) => calls.cleanups.push(options),
    consumeRetry: () => {
      calls.retries += 1;
    },
    getErrorContext: () => ({
      contentId: "42",
      contentType: "live",
      currentUrl: state.urls.currentUrl,
      fallbackAttempts: 1,
      retryCount: 2,
      sourceType: "xtream",
      streamType: "mpegts",
      streamingMode: "auto",
      usingAVPlayer: false,
      video: { id: "video" },
    }),
    getHlsRecoveryContext: () => ({ sessionId: state.sessionId, url: state.urls.currentUrl }),
    getHlsRecoveryCoordinator: () => hls,
    getMpegtsRecoveryCoordinator: () => mpegts,
    getPageProtocol: () => state.protocol,
    getSessionId: () => state.sessionId,
    getStreamUrls: () => ({ ...state.urls }),
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    observePlaybackState: (playbackState, reason) => calls.observed.push([playbackState, reason]),
    playNative: () => calls.plays.push("native"),
    playWithMpegts: () => calls.plays.push("mpegts"),
    pushEvent: (event, payload) => calls.pushes.push([event, payload]),
    recordError: () => {
      calls.records += 1;
    },
    showErrorWithDiagnostics: (...args) => calls.errors.push(args),
    showPlaybackError: (message) => calls.playbackErrors.push(message),
    teardownStreamLoaderForTransition: (sessionId) => {
      calls.teardowns.push(sessionId);
      return Promise.resolve(state.nextSessionId);
    },
    tryAVPlayerFallback: () => calls.plays.push("avplayer"),
    useDirectStream: () => {
      calls.direct += 1;
      state.urls = { ...state.urls, currentUrl: state.urls.streamUrl, useProxy: false };
    },
  };
  const dependencies = {
    canRetryDirectStream: (options) => {
      calls.canTryDirect = options;
      return true;
    },
    createErrorReport: (error, context) => ({ error, context }),
    detectErrorPatterns: () => ["pattern"],
    formatErrorForLog: (report) => `report:${report.error.message}`,
    isCancelledError: (error) => error?.cancelled === true,
    isDirectStreamUrlAllowed: () => state.directAllowed,
    isMpegtsSupported: () => state.mpegtsSupported,
    ...depOverrides,
  };
  const policy = createEngineRecoveryPolicy({ dependencies, host, logger: silentLogger });

  return { calls, dependencies, host, policy, state };
}

test("the host contract and telemetry dependencies are validated up front", () => {
  const { dependencies, host } = createHarness();

  assert.throws(
    () => createEngineRecoveryPolicy({ dependencies, host: null }),
    /requires an activation host/,
  );
  for (const method of ENGINE_RECOVERY_HOST_METHODS) {
    assert.throws(
      () => createEngineRecoveryPolicy({ dependencies, host: { ...host, [method]: undefined } }),
      new RegExp(`missing: ${method}`),
    );
  }
  for (const name of ENGINE_RECOVERY_TELEMETRY_DEPENDENCIES) {
    assert.throws(
      () =>
        createEngineRecoveryPolicy({
          dependencies: { ...dependencies, [name]: undefined },
          host,
        }),
      new RegExp(`missing: ${name}`),
    );
  }
});

test("handleStreamError reports telemetry and routes HLS errors to the coordinator", () => {
  const { calls, policy } = createHarness();

  policy.handleStreamError("hls", { details: "manifestLoadError", fatal: true });

  assert.equal(calls.records, 1);
  assert.equal(calls.pushes.length, 1);
  const [event, payload] = calls.pushes[0];
  assert.equal(event, "player_error");
  assert.deepEqual(payload.error, { message: "manifestLoadError", type: "hls" });
  assert.equal(payload.context.streamUrl, "https://proxy/live.ts");
  assert.equal(payload.context.retryCount, 2);
  assert.equal(payload.context.fallbackAttempt, 1);
  assert.equal(payload.context.fatal, true);
  assert.deepEqual(payload.context.playerState, {
    usingAVPlayer: false,
    streamingMode: "auto",
    streamType: "mpegts",
    sourceType: "xtream",
  });
  assert.deepEqual(payload.patterns, ["pattern"]);
  assert.equal(calls.hls.length, 1);
  assert.deepEqual(calls.hls[0][1], { sessionId: 3, url: "https://proxy/live.ts" });
  assert.equal(calls.mpegts.length, 0);
});

test("handleStreamError routes MPEG-TS errors to the MPEG-TS coordinator", () => {
  const { calls, policy } = createHarness();

  policy.handleStreamError("mpegts", { errorDetail: "NetworkTimeout" });

  assert.equal(calls.pushes[0][1].error.message, "NetworkTimeout");
  assert.equal(calls.hls.length, 0);
  assert.equal(calls.mpegts.length, 1);

  policy.handleStreamError("native", {});
  assert.equal(calls.pushes[1][1].error.message, "Stream error");
  assert.equal(calls.mpegts.length, 1);
});

test("HLS outcomes: ignored errors log, auth errors request a token refresh, running recovery waits", () => {
  const harness = createHarness();
  const { calls, policy, state } = harness;

  assert.deepEqual(policy.handleHlsStreamError({}).decision, state.decision);
  assert.deepEqual(calls.pushes, []);

  state.decision = { outcome: HLS_RECOVERY_OUTCOME.REFRESH_TOKEN };
  policy.handleHlsStreamError({});
  assert.deepEqual(calls.pushes, [["request_token_refresh", {}]]);

  state.decision = {
    outcome: HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING,
    reason: HLS_RECOVERY_REASON.NETWORK_RESTART,
    nextAttempts: 2,
  };
  policy.handleHlsStreamError({});
  state.decision = {
    outcome: HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED,
    reason: "custom",
    operation: "loadHlsSoft",
  };
  policy.handleHlsStreamError({});
  assert.deepEqual(calls.plays, []);
  assert.deepEqual(calls.errors, []);
});

test("an unavailable manifest falls back to mpegts.js while retries remain", () => {
  const { calls, policy, state } = createHarness();
  state.decision = {
    outcome: HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED,
    reason: HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE,
  };

  policy.handleHlsStreamError({});

  assert.equal(calls.retries, 1);
  assert.deepEqual(calls.observed, [[PLAYBACK_STATE.RECOVERING, "hls_to_mpegts_fallback"]]);
  assert.deepEqual(calls.cleanups, [{ preservePlaybackState: true }]);
  assert.deepEqual(calls.plays, ["mpegts"]);

  state.canRetry = false;
  policy.handleHlsStreamError({});
  assert.equal(calls.retries, 1);
  assert.equal(calls.errors.length, 1);
  assert.match(calls.errors[0][0], /servidor indisponível/);
  assert.deepEqual(calls.errors[0][1], { message: "Manifest load failed", type: "network" });
  assert.equal(calls.errors[0][2], true);
});

test("an unavailable manifest without mpegts.js support shows the server error", () => {
  const { calls, policy, state } = createHarness({ state: { mpegtsSupported: false } });
  state.decision = {
    outcome: HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED,
    reason: HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE,
  };

  policy.handleHlsStreamError({});

  assert.deepEqual(calls.plays, []);
  assert.equal(calls.retries, 0);
  assert.match(calls.errors[0][0], /servidor indisponível/);
});

test("other fatal HLS errors fall back to mpegts.js, then native, then a codec error", () => {
  const { calls, policy, state } = createHarness();
  state.decision = {
    outcome: HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED,
    reason: HLS_RECOVERY_REASON.MEDIA_SOFT_RELOAD,
  };

  policy.handleHlsStreamError({});
  assert.deepEqual(calls.plays, ["mpegts"]);
  assert.deepEqual(calls.observed, [[PLAYBACK_STATE.RECOVERING, "hls_engine_fallback"]]);

  state.mpegtsSupported = false;
  policy.handleHlsStreamError({});
  assert.deepEqual(calls.plays, ["mpegts", "native"]);
  assert.equal(calls.retries, 2);
  assert.deepEqual(calls.cleanups, [
    { preservePlaybackState: true },
    { preservePlaybackState: true },
  ]);

  state.canRetry = false;
  policy.handleHlsStreamError({});
  assert.deepEqual(calls.plays, ["mpegts", "native"]);
  assert.match(calls.errors[0][0], /formato não suportado/);
  assert.deepEqual(calls.errors[0][1], { message: "Media format error", type: "codec" });
});

test("unknown HLS outcomes are treated as an unhandled fatal soft reload fallback", () => {
  const { calls, policy, state } = createHarness();
  state.decision = { outcome: "mystery", reason: "whatever" };

  policy.handleHlsStreamError({});

  assert.deepEqual(calls.plays, ["mpegts"]);
  assert.equal(calls.retries, 1);
  assert.ok(HLS_RECOVERY_OPERATION.SOFT_RELOAD);
  assert.ok(HLS_RECOVERY_REASON.UNHANDLED_FATAL);
});

test("reportHlsRecoveryFailure ignores cancelled loads and surfaces other failures", () => {
  const { calls, policy } = createHarness();

  policy.reportHlsRecoveryFailure({ cancelled: true, message: "cancelled" });
  assert.deepEqual(calls.errors, []);

  policy.reportHlsRecoveryFailure(new Error("boom"));
  assert.equal(calls.errors.length, 1);
  assert.deepEqual(calls.errors[0][1], { message: "boom", type: "network" });
  assert.equal(calls.errors[0][2], true);

  policy.reportHlsRecoveryFailure("plain");
  assert.deepEqual(calls.errors[1][1], { message: "plain", type: "network" });
});

test("recoverFromMpegtsError hands the coordinator the session context and fallbacks", async () => {
  const { calls, policy, state } = createHarness({ state: { canTryAVPlayer: true } });

  assert.equal(await policy.recoverFromMpegtsError({ errorType: "NetworkError" }), "handled");
  const { actions, data } = calls.mpegts[0];
  assert.deepEqual(data, { errorType: "NetworkError" });
  assert.equal(actions.sessionId, 3);
  assert.equal(actions.canTryAVPlayer, true);
  assert.equal(actions.canTryDirect, true);
  assert.deepEqual(calls.canTryDirect, {
    currentUrl: "https://proxy/live.ts",
    pageProtocol: "https:",
    streamUrl: "http://direct/live.ts",
    useProxy: true,
  });

  assert.equal(actions.isCurrent(), true);
  assert.equal(await actions.cleanup(), true);
  assert.deepEqual(calls.teardowns, [3]);
  assert.equal(actions.isCurrent(), false);
  state.sessionId = 4;
  assert.equal(actions.isCurrent(), true);

  actions.refreshToken();
  assert.deepEqual(calls.pushes, [["request_token_refresh", {}]]);

  actions.retryMpegts({ reason: "decoder" });
  actions.fallbackAVPlayer();
  actions.fallbackNative();
  assert.deepEqual(calls.plays, ["mpegts", "avplayer", "native"]);

  actions.onFailure(new Error("dead"));
  assert.deepEqual(calls.playbackErrors, ["Erro ao recuperar o stream ao vivo"]);
  state.sessionId = 9;
  actions.onFailure(new Error("dead"));
  assert.equal(calls.playbackErrors.length, 1);
});

test("recoverFromMpegtsError cleanup reports a lost session and the direct retry honours mixed content", async () => {
  const { calls, policy, state } = createHarness({ state: { nextSessionId: null } });

  await policy.recoverFromMpegtsError({});
  const { actions } = calls.mpegts[0];
  assert.equal(await actions.cleanup(), false);
  assert.equal(actions.isCurrent(), true);

  state.directAllowed = false;
  actions.retryDirect();
  assert.equal(calls.direct, 0);
  assert.deepEqual(calls.plays, ["mpegts"]);

  state.directAllowed = true;
  actions.retryDirect();
  assert.equal(calls.direct, 1);
  assert.deepEqual(calls.plays, ["mpegts", "mpegts"]);
  assert.equal(state.urls.useProxy, false);
  assert.equal(state.urls.currentUrl, "http://direct/live.ts");
});
