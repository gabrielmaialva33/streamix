import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_STATE } from "../player/engine_contract.js";
import {
  createMediaEventBindings,
  MEDIA_EVENT_BINDINGS_HOST_METHODS,
} from "../player/media_event_bindings.js";

function createLifecycle() {
  const listeners = [];
  const push = (optional) => (target, event, handler, options) => {
    listeners.push({ target, event, handler, options, optional });
    return () => {};
  };
  const scope = { listen: push(false), listenOptional: push(true) };
  const dispatch = (target, event, payload) => {
    for (const listener of listeners) {
      if (listener.target === target && listener.event === event) listener.handler(payload);
    }
  };
  return { dispatch, listeners, scope };
}

function createHarness({ state: overrides = {}, slider = null } = {}) {
  const calls = { buffering: [], emitted: [], host: [], ios: [], queued: [], ui: [] };
  const state = {
    holdOnPlay: false,
    iosPwa: false,
    native: true,
    userPaused: false,
    vod: true,
    ...overrides,
  };
  const record =
    (name) =>
    (...args) => {
      calls.host.push([name, ...args]);
    };
  const recorder = (bucket) =>
    new Proxy(
      {},
      {
        get:
          (_target, method) =>
          (...args) => {
            bucket.push([method, ...args]);
          },
      },
    );
  const ios = {
    handlePageHide: (event) => calls.ios.push(["handlePageHide", event]),
    handleVisibilityChange: () => calls.ios.push(["handleVisibilityChange"]),
    pauseWasUserInitiated: () => state.userPaused,
    persist: (options) => calls.ios.push(["persist", options]),
    resume: () => calls.ios.push(["resume"]),
  };
  const host = {
    emergencyStopPlayback: record("emergencyStopPlayback"),
    emitPlaybackEvent: (name) => calls.emitted.push(name),
    flushPlaybackMetrics: record("flushPlaybackMetrics"),
    getBufferingController: () => recorder(calls.buffering),
    getIosPwaController: () => ios,
    getUiController: () => recorder(calls.ui),
    getWatchPartyPolicy: () => ({ shouldReapplyHoldOnPlay: () => state.holdOnPlay }),
    handleNativeVolumeChange: record("handleNativeVolumeChange"),
    handlePlaybackEnded: record("handlePlaybackEnded"),
    handlePlaybackPaused: record("handlePlaybackPaused"),
    handlePlaybackStarted: record("handlePlaybackStarted"),
    isIosPwaMode: () => state.iosPwa,
    isVodContent: () => state.vod,
    observePlaybackState: record("observePlaybackState"),
    reportDuration: record("reportDuration"),
    reportProgress: record("reportProgress"),
    setPlaybackRate: record("setPlaybackRate"),
    setVolume: record("setVolume"),
    setWatchPartySyncHold: record("setWatchPartySyncHold"),
    toggleAVPlayerPreference: record("toggleAVPlayerPreference"),
    toggleFullscreen: record("toggleFullscreen"),
    toggleMute: record("toggleMute"),
    togglePiP: record("togglePiP"),
    togglePlayPause: record("togglePlayPause"),
    updateBufferBar: record("updateBufferBar"),
    updateTimeUI: record("updateTimeUI"),
    usesNativePlaybackEvents: () => state.native,
  };
  const root = { querySelector: (selector) => (selector === "#volume-slider" ? slider : null) };
  const video = { duration: 120.7, playbackRate: 1.5 };
  const documentRef = { name: "document" };
  const windowRef = { name: "window" };
  const lifecycle = createLifecycle();
  const bindings = createMediaEventBindings({
    host,
    lifecycle: lifecycle.scope,
    root,
    video,
    documentRef,
    windowRef,
    queueTask: (task) => calls.queued.push(task),
  });

  return { bindings, calls, documentRef, host, lifecycle, root, state, video, windowRef };
}

function hostCalls(calls, name) {
  return calls.host.filter(([called]) => called === name).map(([, ...args]) => args);
}

test("the host and lifecycle contracts are validated up front", () => {
  const { host, lifecycle } = createHarness();

  assert.throws(
    () => createMediaEventBindings({ host: null, lifecycle: lifecycle.scope }),
    /requires an activation host/,
  );
  assert.throws(() => createMediaEventBindings({ host, lifecycle: {} }), /lifecycle scope/);
  for (const method of MEDIA_EVENT_BINDINGS_HOST_METHODS) {
    assert.throws(
      () =>
        createMediaEventBindings({
          host: { ...host, [method]: undefined },
          lifecycle: lifecycle.scope,
        }),
      new RegExp(`missing: ${method}`),
    );
  }
});

test("control events route to host commands and the volume slider scales to 0..1", () => {
  const slider = { id: "volume-slider" };
  const { bindings, calls, lifecycle, root } = createHarness({ slider });
  bindings.bindControlEvents();

  lifecycle.dispatch(root, "player:toggle-play");
  lifecycle.dispatch(root, "player:toggle-mute");
  lifecycle.dispatch(root, "player:toggle-fullscreen");
  lifecycle.dispatch(root, "player:toggle-pip");
  lifecycle.dispatch(root, "player:toggle-avplayer");
  lifecycle.dispatch(root, "player:set-speed", { detail: { speed: "1.25" } });
  lifecycle.dispatch(root, "player:set-speed", { detail: null });
  lifecycle.dispatch(slider, "input", { target: { value: "35" } });

  assert.deepEqual(
    calls.host.map(([name]) => name),
    [
      "togglePlayPause",
      "toggleMute",
      "toggleFullscreen",
      "togglePiP",
      "toggleAVPlayerPreference",
      "setPlaybackRate",
      "setPlaybackRate",
      "setVolume",
    ],
  );
  assert.deepEqual(hostCalls(calls, "setPlaybackRate"), [[1.25], [1]]);
  assert.deepEqual(hostCalls(calls, "setVolume"), [[0.35]]);
  assert.ok(lifecycle.listeners.every((listener) => listener.optional === false));
});

test("control bindings skip the volume slider when the DOM has none", () => {
  const { bindings, lifecycle } = createHarness();
  bindings.bindControlEvents();

  assert.equal(
    lifecycle.listeners.some((listener) => listener.event === "input"),
    false,
  );
});

test("play updates the UI, persists iOS PWA state, and notifies the playback bridge", () => {
  const { bindings, calls, lifecycle, video } = createHarness();
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "play");

  assert.deepEqual(calls.ui, [["updatePlayPauseUI", false]]);
  assert.deepEqual(calls.ios, [
    ["persist", { userPaused: false, wasPlaying: true, reason: "play" }],
  ]);
  assert.deepEqual(calls.emitted, ["play"]);
  assert.deepEqual(calls.queued, []);
});

test("play reapplies the watch party hold instead of resuming the UI", () => {
  const { bindings, calls, lifecycle, video } = createHarness({ state: { holdOnPlay: true } });
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "play");

  assert.deepEqual(calls.ui, []);
  assert.deepEqual(calls.emitted, []);
  assert.equal(calls.queued.length, 1);
  calls.queued[0]();
  assert.deepEqual(hostCalls(calls, "setWatchPartySyncHold"), [[true]]);
});

test("pause records the user intent and only reports native playback to the bridge", () => {
  const { bindings, calls, lifecycle, state, video } = createHarness({
    state: { userPaused: true },
  });
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "pause");
  assert.deepEqual(calls.ui, [["updatePlayPauseUI", true]]);
  assert.deepEqual(calls.buffering, [["handlePause"]]);
  assert.deepEqual(calls.ios, [
    ["persist", { userPaused: true, wasPlaying: false, reason: "pause" }],
  ]);
  assert.deepEqual(hostCalls(calls, "handlePlaybackPaused"), [[]]);
  assert.deepEqual(calls.emitted, ["pause"]);

  state.native = false;
  lifecycle.dispatch(video, "pause");
  assert.deepEqual(hostCalls(calls, "handlePlaybackPaused"), [[]]);
  assert.deepEqual(calls.emitted, ["pause"]);
});

test("ended, volume, time, rate, and progress events route to the host", () => {
  const { bindings, calls, lifecycle, state, video } = createHarness();
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "ended");
  lifecycle.dispatch(video, "volumechange");
  lifecycle.dispatch(video, "loadedmetadata");
  lifecycle.dispatch(video, "ratechange");
  lifecycle.dispatch(video, "progress");

  assert.deepEqual(hostCalls(calls, "handlePlaybackEnded"), [[]]);
  assert.deepEqual(hostCalls(calls, "flushPlaybackMetrics"), [["completed"]]);
  assert.deepEqual(hostCalls(calls, "handleNativeVolumeChange"), [[]]);
  assert.deepEqual(hostCalls(calls, "updateTimeUI"), [[]]);
  assert.deepEqual(calls.ui, [["updateSpeedUI", 1.5]]);
  assert.deepEqual(hostCalls(calls, "updateBufferBar"), [[]]);
  assert.deepEqual(calls.buffering, [["handleProgress"]]);

  state.native = false;
  lifecycle.dispatch(video, "ended");
  assert.deepEqual(hostCalls(calls, "handlePlaybackEnded"), [[]]);
  assert.deepEqual(hostCalls(calls, "flushPlaybackMetrics"), [["completed"], ["completed"]]);
});

test("timeupdate keeps the UI update ahead of VOD progress reporting", () => {
  const { bindings, calls, lifecycle, video } = createHarness();
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "timeupdate");

  assert.deepEqual(
    calls.host.map(([name]) => name),
    ["updateTimeUI", "reportProgress"],
  );
  assert.deepEqual(calls.buffering, [["handleTimeUpdate"]]);
});

test("VOD content reports finite durations while live content binds no progress listeners", () => {
  const vod = createHarness();
  vod.bindings.bindMediaEvents();
  vod.lifecycle.dispatch(vod.video, "durationchange");
  assert.deepEqual(hostCalls(vod.calls, "reportDuration"), [[120]]);

  vod.video.duration = Number.POSITIVE_INFINITY;
  vod.lifecycle.dispatch(vod.video, "durationchange");
  assert.deepEqual(hostCalls(vod.calls, "reportDuration"), [[120]]);

  const live = createHarness({ state: { vod: false } });
  live.bindings.bindMediaEvents();
  const liveEvents = live.lifecycle.listeners.map((listener) => listener.event);
  assert.equal(liveEvents.includes("durationchange"), false);
  assert.equal(liveEvents.filter((event) => event === "timeupdate").length, 1);
});

test("seek, stall, and playing events drive buffering and playback state", () => {
  const { bindings, calls, lifecycle, state, video } = createHarness();
  bindings.bindMediaEvents();

  lifecycle.dispatch(video, "seeking");
  lifecycle.dispatch(video, "seeked");
  lifecycle.dispatch(video, "waiting");
  lifecycle.dispatch(video, "playing");
  lifecycle.dispatch(video, "canplaythrough");

  assert.deepEqual(calls.buffering, [
    ["handleSeeking"],
    ["handleSeeked"],
    ["handleWaiting"],
    ["handlePlaying"],
    ["handleCanPlayThrough"],
  ]);
  assert.deepEqual(calls.emitted, ["seeked"]);
  assert.deepEqual(hostCalls(calls, "observePlaybackState"), [
    [PLAYBACK_STATE.STALLED, "media_waiting"],
  ]);
  assert.deepEqual(hostCalls(calls, "handlePlaybackStarted"), [[]]);

  state.native = false;
  lifecycle.dispatch(video, "seeked");
  lifecycle.dispatch(video, "playing");
  assert.deepEqual(calls.emitted, ["seeked"]);
  assert.deepEqual(hostCalls(calls, "handlePlaybackStarted"), [[]]);
  assert.deepEqual(hostCalls(calls, "observePlaybackState").at(-1), [
    PLAYBACK_STATE.PLAYING,
    "media_playing",
  ]);
});

test("media listeners are registered as optional so a missing video element is tolerated", () => {
  const { bindings, lifecycle } = createHarness();
  bindings.bindMediaEvents();

  assert.ok(lifecycle.listeners.length > 0);
  assert.ok(lifecycle.listeners.every((listener) => listener.optional === true));
});

test("page lifecycle listeners drive the iOS PWA controller and the emergency stop", () => {
  const { bindings, calls, documentRef, lifecycle, state, windowRef } = createHarness();
  bindings.bindPageLifecycle();

  lifecycle.dispatch(documentRef, "visibilitychange");
  lifecycle.dispatch(windowRef, "pageshow");
  assert.deepEqual(calls.ios, [["handleVisibilityChange"], ["resume"]]);

  const persisted = { persisted: true };
  lifecycle.dispatch(windowRef, "pagehide", persisted);
  assert.deepEqual(calls.ios.at(-1), ["handlePageHide", persisted]);
  assert.deepEqual(hostCalls(calls, "flushPlaybackMetrics"), [["cancelled"]]);
  assert.deepEqual(hostCalls(calls, "emergencyStopPlayback"), [[]]);

  state.iosPwa = true;
  lifecycle.dispatch(windowRef, "pagehide", persisted);
  assert.deepEqual(hostCalls(calls, "flushPlaybackMetrics"), [["cancelled"]]);

  lifecycle.dispatch(windowRef, "beforeunload", { persisted: false });
  assert.deepEqual(hostCalls(calls, "flushPlaybackMetrics"), [["cancelled"], ["cancelled"]]);
  assert.deepEqual(hostCalls(calls, "emergencyStopPlayback"), [[], []]);

  const teardownListeners = lifecycle.listeners.filter((listener) =>
    ["pagehide", "beforeunload"].includes(listener.event),
  );
  assert.equal(teardownListeners.length, 2);
  assert.ok(teardownListeners.every((listener) => listener.options?.capture === true));
});

test("bindAll registers controls, media, and page listeners together", () => {
  const { bindings, lifecycle } = createHarness();
  bindings.bindAll();

  const events = new Set(lifecycle.listeners.map((listener) => listener.event));
  for (const event of ["player:toggle-play", "play", "pagehide", "canplaythrough"]) {
    assert.ok(events.has(event), `missing ${event}`);
  }
});
