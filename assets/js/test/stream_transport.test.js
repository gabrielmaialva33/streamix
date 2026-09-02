import assert from "node:assert/strict";
import test from "node:test";

import {
  createStreamTransport,
  STREAM_TRANSPORT_HOST_METHODS,
} from "../player/stream_transport.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createLoaderClass({ destroyError = null } = {}) {
  const instances = [];
  class FakeLoader {
    constructor(options) {
      this.options = options;
      this.sessionIds = [];
      this.calls = [];
      this.destroyed = false;
      instances.push(this);
    }
    updateSessionId(sessionId) {
      this.sessionIds.push(sessionId);
    }
    updateStreamingMode(mode) {
      this.calls.push(["mode", mode]);
    }
    setQuality(level) {
      this.calls.push(["quality", level]);
    }
    getQualityLevels() {
      return [{ index: 0, height: 720 }];
    }
    getCurrentLevel() {
      return 0;
    }
    setAudioTrack(index) {
      this.calls.push(["audio", index]);
      return true;
    }
    setSubtitleTrack(index) {
      this.calls.push(["subtitle", index]);
      return true;
    }
    destroy() {
      this.destroyed = true;
      if (destroyError) throw destroyError;
      return Promise.resolve();
    }
  }
  return { FakeLoader, instances };
}

function createHarness({ loaderOptions = {}, state: stateOverrides = {} } = {}) {
  const { FakeLoader, instances } = createLoaderClass(loaderOptions);
  const calls = {
    adopt: [],
    codec: [],
    bandwidth: [],
    errors: [],
    labels: [],
    playAfterResume: [],
    presentation: [],
    pushes: [],
    samples: [],
    updates: [],
  };
  const state = {
    adopt: true,
    codecAbr: {
      setCodec: (codec) => calls.codec.push(codec),
      recordBandwidth: (kbps) => calls.bandwidth.push(kbps),
    },
    contentType: "live",
    manual: false,
    monitor: { addSample: (value) => calls.samples.push(value) },
    sessionId: 4,
    streamingMode: "adaptive",
    url: "https://example.test/live.ts",
    ...stateOverrides,
  };
  const host = {
    adoptHlsEngine: (sessionId) => {
      calls.adopt.push(sessionId);
      return state.adopt;
    },
    getCodecAbr: () => state.codecAbr,
    getContentType: () => state.contentType,
    getCurrentUrl: () => state.url,
    getNetworkMonitor: () => state.monitor,
    getPresentation: () => ({
      hideError: () => calls.presentation.push("hideError"),
      hideLoading: () => calls.presentation.push("hideLoading"),
    }),
    getSessionId: () => state.sessionId,
    getStreamingMode: () => state.streamingMode,
    getVideo: () => ({ id: "video" }),
    handleStreamError: (type, data) => calls.errors.push([type, data]),
    isManualQuality: () => state.manual,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    playNativeAfterResume: (sessionId) => calls.playAfterResume.push(sessionId),
    pushEvent: (event, payload) => calls.pushes.push([event, payload]),
    showQualityChange: (label) => calls.labels.push(label),
    updateAudioTracks: () => calls.updates.push("audio"),
    updateQualityList: () => calls.updates.push("quality"),
    updateSubtitleTracks: () => calls.updates.push("subtitle"),
  };
  const transport = createStreamTransport({
    host,
    logger: silentLogger,
    dependencies: { createStreamLoader: (options) => new FakeLoader(options) },
  });
  return { calls, host, instances, state, transport };
}

test("validates the host and creates the loader once with the current session", () => {
  assert.throws(() => createStreamTransport({ host: {} }), /StreamTransport host is missing/);
  assert.ok(STREAM_TRANSPORT_HOST_METHODS.includes("adoptHlsEngine"));

  const { instances, state, transport } = createHarness();
  assert.equal(transport.current, null);
  assert.deepEqual(transport.qualityLevels(), []);
  assert.equal(transport.currentLevel(), -1);
  assert.equal(transport.updateStreamingMode("balanced"), false);
  assert.equal(transport.setQuality(1), false);

  const loader = transport.ensure();
  assert.equal(instances.length, 1);
  assert.equal(loader.options.video.id, "video");
  assert.equal(loader.options.streamingMode, "adaptive");
  assert.equal(loader.options.contentType, "live");
  assert.equal(loader.options.sessionId, 4);

  state.sessionId = 5;
  assert.equal(transport.ensure(), loader, "the loader is reused across sessions");
  assert.deepEqual(loader.sessionIds, [5]);

  assert.equal(transport.updateStreamingMode("balanced"), true);
  assert.equal(transport.setQuality(2), true);
  assert.deepEqual(transport.qualityLevels(), [{ index: 0, height: 720 }]);
  assert.equal(transport.currentLevel(), 0);
  assert.equal(transport.setAudioTrack(1), true);
  assert.equal(transport.setSubtitleTrack(-1), true);
  assert.deepEqual(loader.calls, [
    ["mode", "balanced"],
    ["quality", 2],
    ["audio", 1],
    ["subtitle", -1],
  ]);
});

test("manifest, track and media callbacks run only for the current session and an adopted engine", () => {
  const { calls, state, transport } = createHarness();
  const loader = transport.ensure();
  const { options } = loader;

  options.onManifestParsed({ levels: [1, 2] }, 3);
  assert.deepEqual(calls.adopt, [], "stale sessions never reach the engine");

  state.adopt = false;
  options.onManifestParsed({ levels: [1, 2] }, 4);
  assert.deepEqual(calls.adopt, [4]);
  assert.deepEqual(calls.updates, [], "without an adopted engine nothing is refreshed");

  state.adopt = true;
  options.onManifestParsed({ levels: [1, 2] }, 4);
  assert.deepEqual(calls.presentation, ["hideLoading", "hideError"]);
  assert.deepEqual(calls.updates, ["quality", "audio", "subtitle"]);
  assert.deepEqual(calls.playAfterResume, [4]);

  options.onAudioTracksUpdated([], 4);
  options.onSubtitleTracksUpdated([], 4);
  assert.deepEqual(calls.updates, ["quality", "audio", "subtitle", "audio", "subtitle"]);

  options.onMediaInfo({}, 4);
  assert.deepEqual(calls.presentation, ["hideLoading", "hideError", "hideLoading", "hideError"]);
  options.onMediaInfo({}, 1);
  assert.equal(calls.presentation.length, 4);
});

test("level switches feed codec ABR, telemetry and the auto-quality label", () => {
  const { calls, state, transport } = createHarness();
  const { options } = transport.ensure();

  options.onLevelSwitched(2, { codec: "hevc", height: 1080, bitrate: 5000 }, 4);
  assert.deepEqual(calls.codec, ["hevc"]);
  assert.deepEqual(calls.pushes, [
    ["quality_switched", { level: 2, height: 1080, bitrate: 5000, auto: true }],
  ]);
  assert.deepEqual(calls.labels, ["Auto: 1080p"]);

  state.manual = true;
  options.onLevelSwitched(1, { height: 720 }, 4);
  assert.deepEqual(calls.labels, ["Auto: 1080p"], "manual selections show no auto label");
  assert.equal(calls.pushes[1][1].auto, false);

  state.codecAbr = null;
  options.onLevelSwitched(0, { codec: "avc", height: 480 }, 4);
  assert.deepEqual(calls.codec, ["hevc"], "a missing ABR is tolerated");
  options.onLevelSwitched(0, { height: 480 }, 9);
  assert.equal(calls.pushes.length, 3);
});

test("bandwidth samples, statistics and errors are gated by session", () => {
  const { calls, state, transport } = createHarness();
  const { options } = transport.ensure();

  options.onFragLoaded(2_000_000, 4);
  assert.deepEqual(calls.samples, [2_000_000]);
  assert.deepEqual(calls.bandwidth, [2_000]);
  options.onStatisticsInfo(750, 4);
  assert.deepEqual(calls.samples, [2_000_000, 750]);
  options.onFragLoaded(1, 1);
  options.onStatisticsInfo(1, 1);
  assert.equal(calls.samples.length, 2);

  state.monitor = null;
  state.codecAbr = null;
  options.onFragLoaded(5, 4);

  options.onError("hls", { fatal: true }, 4);
  options.onError("hls", { fatal: true }, 2);
  assert.deepEqual(calls.errors, [["hls", { fatal: true }]]);
});

test("teardown is single-shot, tolerant to throwing destroyers and awaited by transitions", async () => {
  const { instances, transport } = createHarness();
  const loader = transport.ensure();

  const promise = transport.teardown();
  assert.equal(transport.current, null);
  assert.equal(loader.destroyed, true);
  await promise;
  assert.equal(await transport.awaitTeardown(), undefined);
  assert.equal(transport.teardown(), promise, "nothing left to tear down keeps the last promise");

  const failing = createHarness({ loaderOptions: { destroyError: new Error("boom") } });
  failing.transport.ensure();
  await failing.transport.destroy();
  assert.equal(failing.transport.current, null);
  assert.equal(instances.length, 1);
});

test("release drops only the matching loader and the recovery context tracks identity", () => {
  const { state, transport } = createHarness();
  const loader = transport.ensure();

  const context = transport.recoveryContext({ sessionId: 4, url: state.url });
  assert.equal(context.loader, loader);
  assert.equal(context.url, state.url);
  assert.equal(context.isCurrent(), true);

  state.url = "https://example.test/other.ts";
  assert.equal(context.isCurrent(), false, "a new URL invalidates the context");
  state.url = "https://example.test/live.ts";
  state.sessionId = 5;
  assert.equal(context.isCurrent(), false, "a new session invalidates the context");
  state.sessionId = 4;

  assert.equal(transport.release({ other: true }), false);
  assert.equal(transport.release(loader), true);
  assert.equal(transport.current, null);
  assert.equal(context.isCurrent(), false, "a released loader is no longer current");
  assert.equal(transport.recoveryContext({ sessionId: 4, url: state.url }).loader, null);
});
