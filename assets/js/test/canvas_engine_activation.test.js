import assert from "node:assert/strict";
import test from "node:test";

import {
  AVBRIDGE_ENGINE_ACTIVATION_HOST_METHODS,
  createAvbridgeEngineActivation,
} from "../player/avbridge_engine_activation.js";
import { CanvasEngineActivation } from "../player/canvas_engine_activation.js";
import { ENGINE_ID, ENGINE_SELECTION } from "../player/engine_contract.js";
import {
  createH265webEngineActivation,
  H265WEB_ENGINE_ACTIVATION_HOST_METHODS,
} from "../player/h265web_engine_activation.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createWrapperClass({ loadError = null, seekError = null } = {}) {
  const instances = [];
  class FakeWrapper {
    constructor(options) {
      this.options = options;
      this.calls = [];
      this.listeners = new Map();
      this.destroyed = false;
      instances.push(this);
    }
    async load(url, options) {
      this.calls.push(["load", url, options]);
      if (loadError) throw loadError;
    }
    async play() {
      this.calls.push(["play"]);
    }
    pause() {
      this.calls.push(["pause"]);
    }
    async seek(seconds) {
      this.calls.push(["seek", seconds]);
      if (seekError) throw seekError;
    }
    on(event, handler) {
      this.listeners.set(event, handler);
    }
    off(event) {
      this.listeners.delete(event);
    }
    emit(event) {
      this.listeners.get(event)?.();
    }
    async destroy() {
      this.destroyed = true;
      this.calls.push(["destroy"]);
    }
  }
  return { FakeWrapper, instances };
}

function createHarness(
  kind,
  { state: stateOverrides = {}, wrapper = {}, hostOverrides = {} } = {},
) {
  const { FakeWrapper, instances } = createWrapperClass(wrapper);
  const video = { id: "video" };
  const mount = { id: "mount" };
  const calls = {
    emitted: [],
    engineSlot: [],
    flushed: [],
    lifecycle: [],
    playback: [],
    presentation: [],
    progress: 0,
    recorded: 0,
    suppressed: [],
    systemState: [],
    timeUi: 0,
    tracked: [],
    tryAVPlayer: 0,
    using: [],
    pipDisabled: 0,
  };
  const state = {
    attempted: false,
    contentType: "vod",
    engine: null,
    mount,
    resumeTime: 0,
    sessionId: 5,
    ...stateOverrides,
  };
  const host = {
    disablePiPForCanvasPlayback: () => {
      calls.pipDisabled += 1;
    },
    emitPlaybackEvent: (event) => calls.emitted.push(event),
    flushPlaybackMetrics: (outcome) => calls.flushed.push(outcome),
    getAvbridge: () => state.engine,
    getContentType: () => state.contentType,
    getCurrentUrl: () => "https://example.test/uhd.mkv",
    getH265web: () => state.engine,
    getH265webBaseUrl: () => "/sdk/",
    getH265webMount: () => state.mount,
    getPresentation: () => ({
      hideLoading: () => calls.presentation.push("hideLoading"),
      updatePlayPauseUI: (paused) => calls.presentation.push(`playPause:${paused}`),
    }),
    getSessionId: () => state.sessionId,
    getVideo: () => video,
    handlePlaybackEnded: () => calls.playback.push("ended"),
    handlePlaybackPaused: () => calls.playback.push("paused"),
    handlePlaybackStarted: () => calls.playback.push("started"),
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    markAvbridgeAttempted: () => {
      state.attempted = true;
    },
    markH265webAttempted: () => {
      state.attempted = true;
    },
    markPlaying: () => calls.playback.push("markPlaying"),
    recordPlaybackError: () => {
      calls.recorded += 1;
    },
    reportLifecycle: (stage, extra) => calls.lifecycle.push([stage, extra]),
    reportProgress: () => {
      calls.progress += 1;
    },
    setAvbridge: (engine) => {
      state.engine = engine;
      calls.engineSlot.push(engine);
    },
    setH265web: (engine) => {
      state.engine = engine;
      calls.engineSlot.push(engine);
    },
    setNativePlaybackEventsSuppressed: (value) => calls.suppressed.push(value),
    setPlaybackSystemState: (value) => calls.systemState.push(value),
    setUsingAvbridge: (using) => calls.using.push(using),
    setUsingH265web: (using) => calls.using.push(using),
    takeResumeTime: () => state.resumeTime,
    trackManagedEngine: (engineId, engine) => calls.tracked.push([engineId, engine]),
    tryAVPlayerFallback: () => {
      calls.tryAVPlayer += 1;
    },
    updateTimeUI: () => {
      calls.timeUi += 1;
    },
    ...hostOverrides,
  };
  const ticks = [];
  const dependencies = {
    createPlaybackTickThrottle: () => ({
      next: () => ticks.shift() ?? { updateUi: false, reportProgress: false },
    }),
    loadAvbridge: async () => ({ AvbridgeWrapper: FakeWrapper }),
    loadH265web: async () => ({ H265webWrapper: FakeWrapper }),
  };
  const activation =
    kind === "avbridge"
      ? createAvbridgeEngineActivation({ host, logger: silentLogger, dependencies })
      : createH265webEngineActivation({ host, logger: silentLogger, dependencies });
  const request = (overrides = {}) => ({
    activate: () => {
      throw new Error("canvas activations must not chain");
    },
    engineId: activation.id,
    selection: activation.selection,
    sessionId: state.sessionId,
    url: host.getCurrentUrl(),
    ...overrides,
  });

  return { activation, calls, host, instances, request, state, ticks, video, mount };
}

test("both activations validate their host contracts and expose their identities", () => {
  assert.throws(
    () => createAvbridgeEngineActivation({ host: {} }),
    /AvbridgeEngineActivation host is missing/,
  );
  assert.throws(
    () => createH265webEngineActivation({ host: {} }),
    /H265webEngineActivation host is missing/,
  );
  assert.ok(AVBRIDGE_ENGINE_ACTIVATION_HOST_METHODS.includes("setUsingAvbridge"));
  assert.ok(H265WEB_ENGINE_ACTIVATION_HOST_METHODS.includes("getH265webMount"));

  const { activation: avbridge } = createHarness("avbridge");
  const { activation: h265web } = createHarness("h265web");
  assert.ok(avbridge instanceof CanvasEngineActivation);
  assert.equal(avbridge.id, ENGINE_ID.AVBRIDGE);
  assert.equal(avbridge.selection, ENGINE_SELECTION.AVBRIDGE);
  assert.equal(h265web.id, ENGINE_ID.H265WEB);
  assert.equal(h265web.selection, ENGINE_SELECTION.H265WEB);
});

test("avbridge loads, resumes, plays and reports playback start itself", async () => {
  const { activation, calls, instances, request, state, video } = createHarness("avbridge", {
    state: { resumeTime: 30 },
  });

  assert.equal(await activation.activate(request()), true);

  assert.deepEqual(
    calls.suppressed,
    [false],
    "avbridge renders through <video>, native events resume",
  );
  assert.equal(calls.pipDisabled, 1);
  assert.equal(state.attempted, true);
  assert.deepEqual(calls.lifecycle, [["player_engine_selected", { engine: ENGINE_ID.AVBRIDGE }]]);

  const wrapper = instances[0];
  assert.equal(wrapper.options.video, video);
  assert.deepEqual(wrapper.calls, [
    ["load", "https://example.test/uhd.mkv", { startTime: 30 }],
    ["seek", 30],
    ["play"],
  ]);
  assert.equal(calls.tracked[0][0], ENGINE_ID.AVBRIDGE);
  assert.equal(calls.tracked[0][1], state.engine);
  assert.deepEqual(calls.using, [true]);
  assert.deepEqual(calls.presentation, ["hideLoading"]);
  assert.deepEqual(calls.playback, ["started", "markPlaying"]);
  assert.equal(calls.tryAVPlayer, 0);
});

test("h265web mounts into its canvas host, mirrors wrapper events and leaves start to the playing event", async () => {
  const { activation, calls, instances, mount, request, state, ticks, video } =
    createHarness("h265web");

  assert.equal(await activation.activate(request()), true);

  assert.deepEqual(calls.suppressed, [], "h265web keeps the native event suppression untouched");
  const wrapper = instances[0];
  assert.equal(wrapper.options.video, video);
  assert.equal(wrapper.options.mountEl, mount);
  assert.equal(wrapper.options.baseUrl, "/sdk/");
  assert.deepEqual(wrapper.calls, [
    ["load", "https://example.test/uhd.mkv", { startTime: 0, autoPlay: true }],
    ["play"],
  ]);
  assert.deepEqual(calls.playback, ["markPlaying"]);

  wrapper.emit("playing");
  assert.deepEqual(calls.playback, ["markPlaying", "started"]);
  assert.deepEqual(calls.emitted, ["play"]);
  assert.ok(calls.presentation.includes("playPause:false"));

  ticks.push({ updateUi: true, reportProgress: true }, { updateUi: false, reportProgress: false });
  wrapper.emit("timeupdate");
  wrapper.emit("timeupdate");
  assert.equal(calls.timeUi, 1);
  assert.equal(calls.progress, 1);

  wrapper.emit("paused");
  wrapper.emit("ended");
  assert.deepEqual(calls.emitted, ["play", "pause"]);
  assert.deepEqual(calls.flushed, ["completed"]);

  state.sessionId += 1;
  wrapper.emit("playing");
  assert.deepEqual(
    calls.emitted,
    ["play", "pause"],
    "stale sessions are ignored by mirrored events",
  );
});

test("a missing h265web mount fails over to AVPlayer without touching the engine slot", async () => {
  const { activation, calls, request, state } = createHarness("h265web", {
    state: { mount: null },
  });

  assert.equal(await activation.activate(request()), false);

  assert.equal(state.engine, null);
  assert.deepEqual(calls.systemState, ["none"]);
  assert.equal(calls.recorded, 1);
  assert.deepEqual(calls.lifecycle.at(-1), [
    "player_engine_fallback",
    {
      from: ENGINE_ID.H265WEB,
      to: ENGINE_ID.AVPLAYER,
      reason: "h265web mount element (#h265web-mount) not found in template",
    },
  ]);
  assert.deepEqual(calls.using, [false]);
  assert.equal(calls.tryAVPlayer, 1);
});

test("load failures destroy the provisional engine and fall back only while the session is current", async () => {
  const failing = createHarness("avbridge", {
    wrapper: { loadError: new Error("decoder unsupported") },
  });
  assert.equal(await failing.activation.activate(failing.request()), false);
  assert.equal(failing.instances[0].destroyed, true);
  assert.equal(failing.state.engine, null);
  assert.deepEqual(failing.calls.using, [false]);
  assert.equal(failing.calls.tryAVPlayer, 1);
  assert.deepEqual(failing.calls.systemState, ["none"]);

  const superseded = createHarness("avbridge", {
    hostOverrides: {
      trackManagedEngine: () => {
        superseded.state.sessionId += 1;
        throw new Error("registry closed");
      },
    },
  });
  assert.equal(await superseded.activation.activate(superseded.request()), false);
  assert.equal(superseded.calls.tryAVPlayer, 0, "no fallback for a superseded session");
});

test("a session superseded during the load destroys the engine without marking it active", async () => {
  const harness = createHarness("h265web");
  harness.host.trackManagedEngine = () => {
    harness.state.sessionId += 1;
  };

  assert.equal(await harness.activation.activate(harness.request()), false);
  assert.equal(harness.instances[0].destroyed, true);
  assert.equal(harness.state.engine, null);
  assert.deepEqual(harness.calls.using, []);
  assert.equal(harness.calls.tryAVPlayer, 0);
});

test("a rejected resume seek is tolerated and playback still starts", async () => {
  const { activation, calls, instances, request } = createHarness("avbridge", {
    state: { resumeTime: 12 },
    wrapper: { seekError: new Error("not seekable yet") },
  });

  assert.equal(await activation.activate(request()), true);
  assert.deepEqual(
    instances[0].calls.map(([name]) => name),
    ["load", "seek", "play"],
  );
  assert.deepEqual(calls.playback, ["started", "markPlaying"]);
});
