import assert from "node:assert/strict";
import test from "node:test";

import {
  AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS,
  AVPLAYER_FALLBACK_BLOCKED_MESSAGE,
  AVPLAYER_RECOVERY_FAILED_MESSAGE,
  createAvPlayerEngineActivation,
} from "../player/avplayer_engine_activation.js";
import { ENGINE_ID, ENGINE_SELECTION } from "../player/engine_contract.js";
import { createPlaybackEngineTransitionController } from "../player/playback_engine_transition_controller.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

class FakeClassList {
  constructor() {
    this.names = new Set();
  }
  add(name) {
    this.names.add(name);
  }
  remove(name) {
    this.names.delete(name);
  }
  contains(name) {
    return this.names.has(name);
  }
}

class FakeMount {
  constructor() {
    this.classList = new FakeClassList();
    this.classList.add("hidden");
    this.cleared = 0;
  }
  replaceChildren() {
    this.cleared += 1;
  }
}

class FakeVideo {
  constructor() {
    this.classList = new FakeClassList();
    this.currentTime = 12;
    this.paused = false;
    this.pauseCalls = 0;
  }
  pause() {
    this.pauseCalls += 1;
    this.paused = true;
  }
}

function createWrapperClass(behaviour = {}) {
  const instances = [];
  class FakeAVPlayerWrapper {
    constructor(options) {
      this.options = options;
      this.calls = [];
      this.destroyed = false;
      instances.push(this);
    }
    init() {
      this.calls.push(["init"]);
    }
    async load(url, options) {
      this.calls.push(["load", url, options]);
      if (behaviour.loadError) throw behaviour.loadError;
    }
    async play() {
      this.calls.push(["play"]);
    }
    pause() {
      this.calls.push(["pause"]);
    }
    async seek(seconds) {
      this.calls.push(["seek", seconds]);
    }
    setVolume(volume) {
      this.calls.push(["setVolume", volume]);
    }
    getCurrentTime() {
      return behaviour.currentTime ?? 30;
    }
    isPlaying() {
      return true;
    }
    async destroy() {
      this.destroyed = true;
      this.calls.push(["destroy"]);
    }
  }
  return { FakeAVPlayerWrapper, instances };
}

function createFrameApi() {
  const frames = [];
  return {
    frames,
    requestAnimationFrame(callback) {
      frames.push(callback);
      return frames.length;
    },
    cancelAnimationFrame(handle) {
      frames[handle - 1] = null;
    },
    tick(timestamp) {
      const callback = frames[frames.length - 1];
      if (callback) callback(timestamp);
    },
  };
}

function createHarness({ state: stateOverrides = {}, hostOverrides = {}, wrapper = {} } = {}) {
  const { FakeAVPlayerWrapper, instances } = createWrapperClass(wrapper);
  const video = new FakeVideo();
  const mount = new FakeMount();
  const frameApi = createFrameApi();
  const calls = {
    audioState: 0,
    debug: [],
    emitted: [],
    errors: [],
    externalSubtitles: [],
    fallbackAllowed: true,
    fallbackAttempts: 0,
    flushed: [],
    forgotten: [],
    initPlayer: [],
    lifecycle: [],
    mediaSession: [],
    nativeAudioCancelled: 0,
    nativeErrorDetached: 0,
    nativeReset: 0,
    nativeSubtitlesReset: 0,
    pipDisabled: 0,
    playback: [],
    presentation: [],
    progress: 0,
    recorded: [],
    released: [],
    savedPositions: [],
    subtitleDelays: [],
    successes: [],
    timeUi: 0,
    tornDown: [],
    tracked: [],
    tracks: [],
    volumeUi: 0,
  };
  const state = {
    avPlayer: null,
    avPlayerAttempted: false,
    contentType: "vod",
    destroyed: false,
    probedAudio: [],
    proxyUrl: "/api/stream/proxy?x=1",
    sessionId: 3,
    sourceType: "gindex",
    streamType: "mkv",
    streamUrl: "https://example.test/movie.mkv",
    subtitleOffsetMs: 250,
    switching: false,
    usingAVPlayer: false,
    ...stateOverrides,
  };
  const controller = createPlaybackEngineTransitionController({
    beginSession: () => {
      state.sessionId += 1;
      return state.sessionId;
    },
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    drainTeardown: async () => {},
    destroyEngine: async (engine) => {
      calls.tornDown.push(engine);
      await engine.destroy();
    },
    onStateChange: (snapshot) => {
      state.switching = snapshot.active;
    },
  });
  const host = {
    applyAudioState: () => {
      calls.audioState += 1;
    },
    canAttemptFallback: () => calls.fallbackAllowed,
    cancelNativeAudioCheck: () => {
      calls.nativeAudioCancelled += 1;
    },
    detachNativeErrorHandler: () => {
      calls.nativeErrorDetached += 1;
    },
    disablePiPForCanvasPlayback: () => {
      calls.pipDisabled += 1;
    },
    emitPlaybackEvent: (event) => calls.emitted.push(event),
    flushPlaybackMetrics: (outcome) => calls.flushed.push(outcome),
    getAVPlayer: () => state.avPlayer,
    getAVPlayerMount: () => mount,
    getContentType: () => state.contentType,
    getCurrentUrl: () => state.streamUrl,
    getFallbackAttempts: () => calls.fallbackAttempts,
    getOutputVolume: () => 0.8,
    getPresentation: () => ({
      hideError: () => calls.presentation.push("hideError"),
      hideLoading: () => calls.presentation.push("hideLoading"),
      showLoading: () => calls.presentation.push("showLoading"),
      updatePlayPauseUI: (paused) => calls.presentation.push(`playPause:${paused}`),
    }),
    getProxyUrl: () => state.proxyUrl,
    getSessionId: () => state.sessionId,
    getSourceType: () => state.sourceType,
    getStreamType: () => state.streamType,
    getStreamUrl: () => state.streamUrl,
    getSubtitleOffsetMs: () => state.subtitleOffsetMs,
    getTransitionController: () => controller,
    getVideo: () => video,
    handlePlaybackEnded: () => calls.playback.push("ended"),
    handlePlaybackPaused: () => calls.playback.push("paused"),
    handlePlaybackStarted: () => calls.playback.push("started"),
    hasProbedAudioTrack: (index) => Boolean(state.probedAudio[index]),
    initPlayer: (options) => calls.initPlayer.push(options),
    isAVPlayerAttempted: () => state.avPlayerAttempted,
    isDestroyed: () => state.destroyed,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    isSwitchingToAVPlayer: () => state.switching,
    isUsingAVPlayer: () => state.usingAVPlayer,
    loadExternalSubtitle: (sessionId) => calls.externalSubtitles.push(sessionId),
    markAVPlayerAttempted: () => {
      state.avPlayerAttempted = true;
    },
    markPlaying: () => calls.playback.push("markPlaying"),
    recordFallbackAttempt: () => {
      calls.fallbackAttempts += 1;
    },
    recordPlaybackError: () => calls.recorded.push("error"),
    releaseEngine: (engineId) => calls.released.push(engineId),
    reportDebug: (stage, extra) => calls.debug.push([stage, extra]),
    reportLifecycle: (stage, extra) => calls.lifecycle.push([stage, extra]),
    reportProgress: () => {
      calls.progress += 1;
    },
    resetNativeMediaElement: () => {
      calls.nativeReset += 1;
    },
    resetNativeSubtitles: () => {
      calls.nativeSubtitlesReset += 1;
    },
    savePlaybackPosition: (time) => calls.savedPositions.push(time),
    setAVPlayer: (engine) => {
      state.avPlayer = engine;
    },
    setAudioTrack: (index) => calls.tracks.push(["audio", index]),
    setSubtitleDelay: (ms) => calls.subtitleDelays.push(ms),
    setSubtitleTrack: (index) => calls.tracks.push(["subtitle", index]),
    setUsingAVPlayer: (using) => {
      state.usingAVPlayer = using;
    },
    showPlaybackError: (message) => calls.errors.push(message),
    syncPiPAvailability: () => calls.presentation.push("syncPiP"),
    takeResumeTime: (fallback) => fallback,
    teardownAVPlayer: async (player) => {
      calls.tornDown.push(player);
      await player.destroy();
    },
    toAbsoluteUrl: (url) => `https://app.test${url}`,
    trackManagedEngine: (engineId, engine) => calls.tracked.push([engineId, engine]),
    updateAudioTracks: async () => [{ id: 0 }, { id: 1 }],
    updateMediaSessionPosition: (options) => calls.mediaSession.push(options),
    updateSubtitleTracks: async () => [{ id: 0 }],
    updateTimeUI: () => {
      calls.timeUi += 1;
    },
    updateVolumeUI: () => {
      calls.volumeUi += 1;
    },
    ...hostOverrides,
  };
  const activation = createAvPlayerEngineActivation({
    host,
    logger: silentLogger,
    dependencies: {
      forgetRecommendedPlayer: (key) => calls.forgotten.push(key),
      frameApi,
      loadAVPlayer: async () => ({ AVPlayerWrapper: FakeAVPlayerWrapper }),
      recordPlayerSuccess: (...args) => calls.successes.push(args),
      timerApi: { setTimeout: (callback) => callback() },
    },
  });
  const request = (overrides = {}) => ({
    activate: () => {
      throw new Error("AVPlayer activation must not chain");
    },
    engineId: ENGINE_ID.AVPLAYER,
    selection: ENGINE_SELECTION.AVPLAYER,
    sessionId: state.sessionId,
    url: state.streamUrl,
    ...overrides,
  });
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

  return {
    activation,
    calls,
    controller,
    flush,
    frameApi,
    host,
    instances,
    mount,
    request,
    state,
    video,
  };
}

test("the activation validates its host contract up front", () => {
  assert.throws(
    () => createAvPlayerEngineActivation({ host: {} }),
    /AvPlayerEngineActivation host is missing/,
  );
  assert.ok(AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS.includes("teardownAVPlayer"));
});

test("startup activation runs the full transaction on the initPlayer session", async () => {
  const { activation, calls, flush, instances, mount, request, state, video } = createHarness();

  const engine = await activation.activate(request());

  assert.equal(engine, state.avPlayer);
  assert.equal(engine.id, ENGINE_ID.AVPLAYER);
  assert.equal(state.avPlayerAttempted, true);
  assert.equal(calls.pipDisabled, 1);
  assert.deepEqual(calls.debug[0], ["start_avplayer_selected", { session_id: 3 }]);
  assert.deepEqual(calls.lifecycle[0], [
    "player_engine_selected",
    { engine: "avplayer", fallback: false, session_id: 3 },
  ]);
  assert.equal(calls.nativeReset, 1);
  assert.equal(calls.nativeSubtitlesReset, 1);
  assert.equal(video.pauseCalls, 0, "startup never pauses the native element as a fallback would");
  assert.equal(mount.cleared, 1);
  assert.equal(mount.classList.contains("hidden"), false);

  const wrapper = instances[0];
  assert.deepEqual(wrapper.calls[0], ["init"]);
  assert.deepEqual(wrapper.calls[1], [
    "load",
    "https://app.test/api/stream/proxy?x=1",
    {
      ext: "mkv",
      isLive: false,
      loadTimeoutMs: 120000,
      maxProbeDuration: 10,
      ioLoaderOptions: { preload: 8 * 1024 * 1024, retryCount: 8, retryInterval: 1 },
    },
  ]);
  assert.deepEqual(wrapper.calls[2], ["setVolume", 0.8]);
  assert.deepEqual(wrapper.calls[3], ["seek", 12]);
  assert.deepEqual(wrapper.calls[4], ["play"]);
  assert.deepEqual(calls.tracked, [[ENGINE_ID.AVPLAYER, engine]]);
  assert.equal(state.usingAVPlayer, true);
  assert.equal(video.classList.contains("hidden"), true);
  assert.deepEqual(calls.mediaSession, [{ force: true }]);
  assert.ok(activation.animating, "rAF loop starts once the transaction completes");

  await flush();
  assert.deepEqual(calls.subtitleDelays, [250]);
  assert.deepEqual(calls.externalSubtitles, [3]);

  wrapper.options.onPlay();
  assert.deepEqual(calls.playback, ["started", "markPlaying"]);
  assert.deepEqual(calls.emitted, ["play"]);
  assert.deepEqual(calls.successes, [
    ["gindex", "avplayer", { sourceType: "gindex", streamType: "mkv" }],
  ]);
  assert.ok(calls.presentation.includes("playPause:false"));

  wrapper.options.onPause();
  wrapper.options.onEnded();
  assert.deepEqual(calls.emitted, ["play", "pause"]);
  assert.deepEqual(calls.flushed, ["completed"]);
  assert.equal(activation.animating, false);
});

test("startup guards: stale session, active transition and an already active AVPlayer", async () => {
  const stale = createHarness();
  assert.equal(await stale.activation.activate(stale.request({ sessionId: 1 })), false);

  const busy = createHarness({ state: { switching: true } });
  assert.equal(await busy.activation.activate(busy.request()), false);
  assert.equal(busy.state.avPlayerAttempted, false);

  const existing = { id: ENGINE_ID.AVPLAYER };
  const active = createHarness({ state: { usingAVPlayer: true, avPlayer: existing } });
  assert.equal(await active.activation.activate(active.request()), existing);
});

test("fallback applies circuit breaker, attempt bookkeeping and pauses the native element", async () => {
  const blocked = createHarness();
  blocked.calls.fallbackAllowed = false;
  assert.equal(await blocked.activation.tryFallback(), false);
  assert.deepEqual(blocked.calls.errors, [AVPLAYER_FALLBACK_BLOCKED_MESSAGE]);

  const attempted = createHarness({ state: { avPlayerAttempted: true } });
  assert.equal(await attempted.activation.tryFallback(), false);
  assert.equal(attempted.calls.fallbackAttempts, 0);

  const { activation, calls, instances, state, video } = createHarness({
    state: { sourceType: "xtream", streamType: "mp4", proxyUrl: null },
  });
  const engine = await activation.tryFallback();

  assert.equal(engine, state.avPlayer);
  assert.equal(calls.fallbackAttempts, 1);
  assert.equal(calls.nativeAudioCancelled, 1);
  assert.equal(calls.nativeErrorDetached, 1);
  assert.equal(video.pauseCalls, 1);
  assert.deepEqual(calls.debug.at(-1), ["try_avplayer_fallback", { fallback_attempts: 1 }]);
  assert.deepEqual(calls.lifecycle[0][1], { engine: "avplayer", fallback: true, session_id: 4 });

  const wrapper = instances[0];
  assert.deepEqual(wrapper.calls[0], [
    "load",
    "https://example.test/movie.mkv",
    { ext: "mp4", isLive: false },
  ]);
  assert.deepEqual(wrapper.calls[1], ["seek", 12], "fallback seeks before restoring volume");
  assert.deepEqual(wrapper.calls[2], ["setVolume", 0.8]);
  assert.equal(
    wrapper.calls.some(([name]) => name === "init"),
    false,
  );

  wrapper.options.onPlay();
  assert.deepEqual(calls.successes, [
    ["mp4", "avplayer", { sourceType: "xtream", streamType: "mp4" }],
  ]);
});

test("track switches restore the selected track after registration", async () => {
  const audio = createHarness({ state: { probedAudio: [true, true] } });
  const engine = await audio.activation.switchWithTrack("audio", 1, 40, false);

  assert.equal(engine, audio.state.avPlayer);
  assert.equal(audio.controller.snapshot().key, null);
  assert.ok(audio.calls.presentation.includes("showLoading"));
  assert.deepEqual(audio.calls.tracks, [["audio", 1]]);
  assert.deepEqual(audio.instances[0].calls.at(-1), ["seek", 40]);
  assert.deepEqual(audio.calls.playback, ["paused"], "shouldPlay=false pauses instead of playing");

  const subtitle = createHarness();
  await subtitle.activation.switchWithTrack("subtitle", -1, 5, true);
  assert.deepEqual(subtitle.calls.tracks, [["subtitle", -1]]);
  assert.deepEqual(subtitle.instances[0].calls.at(-1), ["play"]);

  const busy = createHarness({ state: { switching: true } });
  assert.equal(await busy.activation.switchWithTrack("audio", 0, 0, true), false);
});

test("a failed load rolls back the provisional engine and recovers to native", async () => {
  const { activation, calls, flush, instances, request, state, video } = createHarness({
    wrapper: { loadError: new Error("open stream failed") },
  });

  assert.equal(await activation.activate(request()), false);
  await flush();
  await flush();

  assert.equal(
    instances[0].destroyed,
    true,
    "the provisional engine is destroyed by the controller",
  );
  assert.deepEqual(
    calls.released,
    [ENGINE_ID.AVPLAYER],
    "rollback releases once; a provisional engine has no source to release again",
  );
  assert.equal(state.usingAVPlayer, false);
  assert.deepEqual(calls.forgotten, ["gindex"]);
  assert.deepEqual(calls.savedPositions, [12]);
  assert.deepEqual(calls.recorded, ["error"]);
  assert.equal(video.classList.contains("hidden"), false);
  assert.equal(calls.audioState, 1);
  assert.equal(calls.volumeUi, 1);
  assert.deepEqual(calls.initPlayer, [{ sessionId: 4 }], "native restarts on the recovery session");
  assert.deepEqual(calls.errors, []);
});

test("runtime engine errors after commit tear the engine down and restart native", async () => {
  const { activation, calls, flush, instances, request, state } = createHarness();
  const engine = await activation.activate(request());
  const wrapper = instances[0];

  wrapper.options.onError(new Error("decoder died"));
  await flush();
  await flush();

  assert.equal(calls.tornDown.includes(engine), true, "the committed engine is destroyed once");
  assert.equal(wrapper.destroyed, true);
  assert.equal(state.avPlayer, null);
  assert.deepEqual(calls.initPlayer, [{ sessionId: 4 }]);
  assert.equal(activation.animating, false);
});

test("recovery failures restore the native presentation and report once", async () => {
  const { activation, calls, state } = createHarness({
    hostOverrides: {
      initPlayer: () => {
        throw new Error("native exploded");
      },
    },
  });
  state.avPlayer = { id: ENGINE_ID.AVPLAYER, destroy: async () => {} };

  const result = await activation.recoverToNative({
    sessionId: 3,
    avPlayer: state.avPlayer,
    error: new Error("decoder died"),
    resumeTime: 9,
  });

  assert.equal(result, false);
  assert.deepEqual(calls.errors, [AVPLAYER_RECOVERY_FAILED_MESSAGE]);
  assert.equal(calls.audioState, 2, "presentation restored by the pipeline and again on failure");
  assert.equal(
    await activation.recoverToNative({ sessionId: 1, avPlayer: null, error: {} }),
    false,
  );
});

test("the rAF loop throttles UI ticks and VOD progress reports and stops cleanly", () => {
  const { activation, calls, frameApi, state } = createHarness({ state: { usingAVPlayer: true } });
  state.avPlayer = { id: ENGINE_ID.AVPLAYER };

  activation.startTimeUpdates();
  frameApi.tick(130);
  frameApi.tick(200);
  frameApi.tick(260);
  assert.equal(calls.timeUi, 2, "125ms UI throttle");
  assert.equal(calls.progress, 0, "progress waits for the 10s window");

  frameApi.tick(10_400);
  assert.equal(calls.progress, 1);

  assert.equal(activation.stopTimeUpdates(), true);
  assert.equal(activation.stopTimeUpdates(), false);
  frameApi.tick(20_000);
  assert.equal(calls.timeUi, 3);
});

test("buildLoadOptions only uses the heavy profile for GIndex MKV VOD", () => {
  const gindex = createHarness();
  assert.equal(gindex.activation.buildLoadOptions("mkv", false).loadTimeoutMs, 120000);
  assert.deepEqual(gindex.activation.buildLoadOptions("mkv", true), { ext: "mkv", isLive: true });
  assert.deepEqual(gindex.activation.buildLoadOptions("mp4", false), { ext: "mp4", isLive: false });

  const xtream = createHarness({ state: { sourceType: "xtream" } });
  assert.deepEqual(xtream.activation.buildLoadOptions("mkv", false), { ext: "mkv", isLive: false });
});
