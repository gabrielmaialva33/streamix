import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_ID, ENGINE_SELECTION } from "../player/engine_contract.js";
import {
  createNativeEngineActivation,
  NATIVE_ENGINE_ACTIVATION_HOST_METHODS,
  NATIVE_PLAYBACK_MESSAGES,
} from "../player/native_engine_activation.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.currentTime = 0;
    this.error = null;
    this.paused = true;
    this.readyState = 0;
    this.playCalls = 0;
    this.playError = null;
  }

  play() {
    this.playCalls += 1;
    if (this.playError) return Promise.reject(this.playError);
    this.paused = false;
    return Promise.resolve();
  }
}

function createTimerApi() {
  const timers = new Map();
  let nextId = 1;
  return {
    setTimeout(callback, delay) {
      const id = nextId++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    pending() {
      return [...timers.values()].map((timer) => timer.delay);
    },
    async fire(delay) {
      for (const [id, timer] of [...timers.entries()]) {
        if (timer.delay !== delay) continue;
        timers.delete(id);
        await timer.callback();
      }
    },
  };
}

function createHarness({ state: stateOverrides = {}, hostOverrides = {}, deps = {} } = {}) {
  const video = new FakeVideo();
  const timerApi = createTimerApi();
  const calls = {
    audioProbes: 0,
    configured: [],
    engines: [],
    errors: [],
    externalSubtitles: [],
    lifecycle: [],
    loaded: [],
    presentation: [],
    probes: 0,
    recorded: [],
    registered: [],
    scheduled: [],
    successes: [],
    suppressed: [],
    syncedPiP: 0,
    touchControls: [],
    tryAVPlayer: 0,
  };
  const state = {
    avPlayerAttempted: false,
    bufferManager: null,
    contentType: "vod",
    destroyed: false,
    lifecycleLogs: true,
    nativeEngine: null,
    resumeTime: 0,
    sessionId: 9,
    sourceType: "xtream",
    streamType: "mp4",
    switchingToAVPlayer: false,
    usingAVPlayer: false,
    audioIssue: false,
    ...stateOverrides,
  };
  const host = {
    getContentType: () => state.contentType,
    getCurrentUrl: () => "https://example.test/movie.mp4",
    getNativeBufferManager: () => state.bufferManager,
    getNativeBufferingController: () => ({ prepareSeek() {} }),
    getNativePlaybackEngine: () => state.nativeEngine,
    getPresentation: () => ({
      hideError: () => calls.presentation.push("hideError"),
      hideLoading: () => calls.presentation.push("hideLoading"),
      keepControlsVisible: () => calls.presentation.push("keepControlsVisible"),
      showLoading: () => calls.presentation.push("showLoading"),
    }),
    getSessionId: () => state.sessionId,
    getSourceType: () => state.sourceType,
    getStreamType: () => state.streamType,
    getVideo: () => video,
    isAVPlayerAttempted: () => state.avPlayerAttempted,
    isDestroyed: () => state.destroyed,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    isSwitchingToAVPlayer: () => state.switchingToAVPlayer,
    isUsingAVPlayer: () => state.usingAVPlayer,
    lifecycleLogsEnabled: () => state.lifecycleLogs,
    loadNativeExternalSubtitle: (sessionId) => calls.externalSubtitles.push(sessionId),
    probeMetadataInBackground: () => {
      calls.probes += 1;
    },
    recordPlaybackError: () => {
      calls.recorded.push("error");
    },
    registerMediaElementEngine: (engineId, engine, options) => {
      calls.registered.push([engineId, options]);
      state.nativeEngine = {
        id: engineId,
        engine,
        load: (url) => calls.loaded.push(url),
        play: () => video.play(),
      };
      return state.nativeEngine;
    },
    reportLifecycle: (stage, extra) => calls.lifecycle.push([stage, extra]),
    setNativeBufferManager: (manager) => {
      state.bufferManager = manager;
    },
    setNativePlaybackEventsSuppressed: (value) => calls.suppressed.push(value),
    setNativeTouchControls: (enabled) => calls.touchControls.push(enabled),
    showPlaybackError: (message) => calls.errors.push(message),
    syncPiPAvailability: () => {
      calls.syncedPiP += 1;
    },
    takeResumeTime: (fallback = 0) => state.resumeTime || fallback,
    tryAVPlayerFallback: () => {
      calls.tryAVPlayer += 1;
    },
    ...hostOverrides,
  };
  const activation = createNativeEngineActivation({
    host,
    logger: silentLogger,
    dependencies: {
      buildNativePlaybackSnapshot: () => ({ ready_state: video.readyState }),
      configureNativePlaybackElement: (element, options) =>
        calls.configured.push([element, options]),
      createNativeBufferManager: (element, callbacks) => {
        const manager = {
          element,
          callbacks,
          started: 0,
          start() {
            this.started += 1;
          },
        };
        calls.engines.push("buffer-manager");
        return manager;
      },
      createNativePlaybackEngine: (options) => {
        calls.engines.push(options);
        return { options };
      },
      isAppleTouchDevice: () => false,
      loadAVPlayer: async () => {
        calls.audioProbes += 1;
        return { detectAudioIssue: async () => state.audioIssue };
      },
      recordPlayerSuccess: (...args) => calls.successes.push(args),
      scheduleLowPriority: (callback, options) => {
        calls.scheduled.push(options);
        const cancel = () => {
          cancel.cancelled = true;
        };
        cancel.run = () => {
          if (!cancel.cancelled) callback();
        };
        calls.scheduleCancel = cancel;
        return cancel;
      },
      timerApi,
      waitForNativeReady: async () => calls.presentation.push("waitReady"),
      waitForNativeSeek: async ({ targetTime }) =>
        calls.presentation.push(`waitSeek:${targetTime}`),
      ...deps,
    },
  });
  const request = (overrides = {}) => ({
    activate: () => {
      throw new Error("native activation must not chain");
    },
    engineId: ENGINE_ID.NATIVE,
    selection: ENGINE_SELECTION.NATIVE,
    sessionId: state.sessionId,
    url: host.getCurrentUrl(),
    ...overrides,
  });
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  return { activation, calls, flush, host, request, state, timerApi, video };
}

test("the activation validates its host contract up front", () => {
  assert.throws(
    () => createNativeEngineActivation({ host: {} }),
    /NativeEngineActivation host is missing/,
  );
  assert.ok(NATIVE_ENGINE_ACTIVATION_HOST_METHODS.includes("tryAVPlayerFallback"));
});

test("activation creates and registers an owned native engine, attaches the source and plays", async () => {
  const { activation, calls, flush, request, video } = createHarness({ state: { resumeTime: 42 } });

  assert.equal(activation.activate(request()), true);

  assert.deepEqual(calls.suppressed, [false]);
  assert.equal(calls.syncedPiP, 1);
  assert.deepEqual(calls.touchControls, [false]);
  assert.deepEqual(calls.configured, [[video, { resumeTime: 42 }]]);
  assert.deepEqual(calls.registered, [[ENGINE_ID.NATIVE, { ownsEngine: true }]]);
  assert.equal(calls.engines[0].video, video);
  assert.equal(calls.engines[0].resetSourceOnDestroy, false);
  assert.equal(typeof calls.engines[0].beforePause, "function");
  assert.equal(typeof calls.engines[0].beforeSeek, "function");
  assert.deepEqual(calls.loaded, ["https://example.test/movie.mp4"]);
  assert.deepEqual(calls.lifecycle[0], [
    "player_engine_selected",
    { engine: ENGINE_ID.NATIVE, session_id: 9 },
  ]);
  assert.ok(calls.lifecycle.some(([stage]) => stage === "native_source_attached"));

  await flush();
  assert.ok(calls.presentation.includes("waitReady"));
  assert.ok(calls.presentation.includes("waitSeek:42"));
  assert.equal(video.playCalls, 1);
  assert.ok(calls.lifecycle.some(([stage]) => stage === "native_play_resolved"));
});

test("an existing native engine is reused instead of being recreated", () => {
  const existing = { id: ENGINE_ID.NATIVE, load: () => {}, play: async () => {} };
  const { activation, calls, request } = createHarness({ state: { nativeEngine: existing } });

  activation.activate(request());

  assert.deepEqual(calls.registered, []);
  assert.deepEqual(calls.engines, []);
});

test("confirmed native playback starts buffer monitoring and records codec memory for Xtream MP4", async () => {
  const { activation, calls, request, state, timerApi, video } = createHarness();

  activation.activate(request());
  video.paused = false;
  video.dispatchEvent(new Event("playing"));

  assert.ok(state.bufferManager, "buffer manager created for VOD");
  assert.equal(state.bufferManager.started, 1);
  assert.deepEqual(calls.presentation.slice(0, 2), ["hideLoading", "hideError"]);
  assert.deepEqual(timerApi.pending(), [5000], "no audio probe for Xtream MP4, only success timer");

  await timerApi.fire(5000);
  assert.deepEqual(calls.successes, [
    ["mp4", "native", { sourceType: "xtream", streamType: "mp4" }],
  ]);
});

test("live content never creates a buffer manager and a paused element records no success", async () => {
  const { activation, calls, request, state, timerApi, video } = createHarness({
    state: { contentType: "live", streamType: "ts" },
  });

  activation.activate(request());
  video.dispatchEvent(new Event("playing"));

  assert.equal(state.bufferManager, null);
  assert.deepEqual(timerApi.pending(), [5000], "live still confirms native success");

  video.paused = true;
  await timerApi.fire(5000);
  assert.deepEqual(calls.successes, [], "a paused element records nothing");
});

test("GIndex playback probes audio, schedules the track probe and falls back on audio issues", async () => {
  const { activation, calls, request, state, timerApi, video } = createHarness({
    state: { sourceType: "gindex", streamType: "mkv", audioIssue: true },
  });

  activation.activate(request());
  video.dispatchEvent(new Event("playing"));

  assert.deepEqual(timerApi.pending(), [2000], "audio probe replaces the success timer");
  assert.deepEqual(calls.scheduled, [{ timeout: 5000 }]);

  calls.scheduleCancel.run();
  assert.equal(calls.probes, 1);

  await timerApi.fire(2000);
  assert.equal(calls.audioProbes, 1);
  assert.equal(calls.tryAVPlayer, 1);
  assert.ok(
    calls.lifecycle.some(
      ([stage, extra]) => stage === "native_audio_check_result" && extra.has_audio_issue === true,
    ),
  );
  assert.equal(state.bufferManager?.started, 1);
});

test("background work is cancellable and skips stale sessions", async () => {
  const { activation, calls, request, state, timerApi, video } = createHarness({
    state: { sourceType: "gindex", streamType: "mkv" },
  });

  activation.activate(request());
  video.dispatchEvent(new Event("playing"));
  activation.cancelBackgroundWork();

  assert.deepEqual(timerApi.pending(), []);
  assert.equal(calls.scheduleCancel.cancelled, true);

  activation.checkAudioAndFallback(state.sessionId);
  state.sessionId += 1;
  await timerApi.fire(2000);
  assert.equal(calls.audioProbes, 0, "a superseded session never loads the probe");
});

test("media errors map to messages and unsupported VOD formats try AVPlayer first", () => {
  const unsupported = createHarness();
  unsupported.activation.activate(unsupported.request());
  unsupported.video.error = { code: 4 };
  unsupported.video.dispatchEvent(new Event("error"));
  assert.equal(unsupported.calls.tryAVPlayer, 1);
  assert.deepEqual(unsupported.calls.errors, []);
  assert.deepEqual(unsupported.calls.recorded, ["error"]);

  const attempted = createHarness({ state: { avPlayerAttempted: true } });
  attempted.activation.activate(attempted.request());
  attempted.video.error = { code: 3 };
  attempted.video.dispatchEvent(new Event("error"));
  assert.deepEqual(attempted.calls.errors, [NATIVE_PLAYBACK_MESSAGES.UNSUPPORTED]);

  const network = createHarness();
  network.activation.activate(network.request());
  network.video.error = { code: 2 };
  network.video.dispatchEvent(new Event("error"));
  assert.deepEqual(network.calls.errors, [NATIVE_PLAYBACK_MESSAGES.NETWORK]);
  network.video.dispatchEvent(new Event("error"));
  assert.equal(network.calls.errors.length, 1, "the handler detaches after a terminal error");

  const unknown = createHarness();
  unknown.activation.activate(unknown.request());
  unknown.video.error = null;
  unknown.video.dispatchEvent(new Event("error"));
  assert.deepEqual(unknown.calls.errors, [NATIVE_PLAYBACK_MESSAGES.FAILED]);
});

test("native errors are ignored while AVPlayer owns playback or the session moved on", () => {
  const avplayer = createHarness({ state: { usingAVPlayer: true } });
  avplayer.activation.activate(avplayer.request());
  avplayer.video.error = { code: 2 };
  avplayer.video.dispatchEvent(new Event("error"));
  assert.deepEqual(avplayer.calls.errors, []);

  const stale = createHarness();
  stale.activation.activate(stale.request());
  stale.state.sessionId += 1;
  stale.video.error = { code: 2 };
  stale.video.dispatchEvent(new Event("error"));
  assert.deepEqual(stale.calls.errors, []);
  assert.deepEqual(stale.calls.recorded, []);
});

test("detachErrorHandler removes the native listener for AVPlayer fallbacks", () => {
  const { activation, calls, request, video } = createHarness();

  activation.activate(request());
  assert.equal(activation.detachErrorHandler(), true);
  assert.equal(activation.detachErrorHandler(), false);

  video.error = { code: 2 };
  video.dispatchEvent(new Event("error"));
  assert.deepEqual(calls.errors, []);
});

test("metadata hides loading and loads torrent subtitles once", () => {
  const { activation, calls, request, video } = createHarness({ state: { sourceType: "torrent" } });

  activation.activate(request());
  video.dispatchEvent(new Event("loadedmetadata"));
  video.dispatchEvent(new Event("loadedmetadata"));

  assert.deepEqual(calls.externalSubtitles, [9]);
  assert.equal(calls.presentation.filter((entry) => entry === "hideLoading").length, 1);
});

test("playAfterResume applies autoplay and unsupported-format policies", async () => {
  const blocked = createHarness();
  blocked.video.playError = Object.assign(new Error("gesture"), { name: "NotAllowedError" });
  await blocked.activation.playAfterResume(9);
  assert.deepEqual(blocked.calls.presentation, ["hideLoading", "keepControlsVisible"]);
  assert.deepEqual(blocked.calls.errors, []);

  const unsupported = createHarness();
  unsupported.video.playError = Object.assign(new Error("codec"), { name: "NotSupportedError" });
  await unsupported.activation.playAfterResume(9);
  assert.deepEqual(unsupported.calls.errors, [], "AVPlayer fallback path stays silent");

  const failed = createHarness({ state: { contentType: "live" } });
  failed.video.playError = Object.assign(new Error("boom"), { name: "NotSupportedError" });
  await failed.activation.playAfterResume(9);
  assert.deepEqual(failed.calls.errors, ["Falha ao iniciar reproducao: boom"]);

  const aborted = createHarness();
  aborted.video.playError = Object.assign(new Error("abort"), { name: "AbortError" });
  await aborted.activation.playAfterResume(9);
  assert.deepEqual(aborted.calls.errors, []);
  assert.deepEqual(aborted.calls.presentation, []);

  const stale = createHarness();
  await stale.activation.playAfterResume(1);
  assert.equal(stale.video.playCalls, 0);
});

test("playAfterResume prefers the registered native engine and defaults the resume time", async () => {
  const plays = [];
  const { activation, host, state } = createHarness({ state: { resumeTime: 7 } });
  state.nativeEngine = { id: ENGINE_ID.NATIVE, play: async () => plays.push("engine") };

  await activation.playAfterResume(host.getSessionId());

  assert.deepEqual(plays, ["engine"]);
});
