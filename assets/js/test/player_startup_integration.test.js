import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { ENGINE_ID, PLAYBACK_STATE } from "../player/engine_contract.js";
import { PlaybackRecoveryGuard } from "../player/playback_recovery_guard.js";
import { PlaybackSession } from "../player/playback_session.js";
import { playerRecommendationKey } from "../player/player_preferences.js";
import { ProviderEngineMemory } from "../player/provider_engine_memory.js";
import { clock } from "./support/playback_clock.js";
import { readSourceSync as readFileSync } from "./support/player_hook_source.js";

// Execute the production hook methods with browser/transport boundaries supplied explicitly.
const source = readFileSync(new URL("../hooks/video_player.js", import.meta.url), "utf8")
  .replace(/^export const (playerComposition|playerSessionLifecycle)/gm, "const $1")
  .replace(/^import[\s\S]*?;\n/gm, "")
  .replace("export default VideoPlayer;", "globalThis.hook = VideoPlayer;");
function harness({ intent = null, streamType = "hls" } = {}) {
  const timerApi = clock();
  const calls = [];
  const bindings = {
    PlaybackRecoveryGuard: class extends PlaybackRecoveryGuard {
      constructor(options) {
        super({ ...options, timerApi, now: timerApi.now });
      }
    },
    log: { info() {}, debug() {} },
    PLAYBACK_STATE,
    ENGINE_ID,
    performance: { now: timerApi.now },
    navigator: { userAgent: "test" },
    engineIdFromRuntime: () => "avbridge",
    isWebCodecsSupported: () => false,
    isMSEInWorkersSupported: () => false,
    resolveStreamType: () => streamType,
    getCapabilitySummary: () => ({}),
    isStandalonePwa: () => false,
    currentDeviceClass: () => "desktop",
    getRecommendedPlayer: (key) => {
      calls.push(["recommendation", key]);
      return null;
    },
    playerRecommendationKey,
    recordPlayerSuccess: (...args) => calls.push(["memory_success", ...args]),
    ProviderEngineMemory: class extends ProviderEngineMemory {
      constructor(options) {
        super({ ...options, timerApi });
      }
    },
    consumePlaybackIntent: () => intent,
    PlaybackStartupController: class {
      constructor(options) {
        this.options = options;
      }
      begin() {}
      attach() {}
      stop() {}
      recover() {}
    },
    selectEngineDecision: () => ({ engine: "native", reason: "capability" }),
    assertEngineSelection: (value) => value,
  };
  vm.runInNewContext(source, bindings);
  const hook = Object.assign({}, bindings.hook, {
    el: { dataset: {} },
    streamUrl: "/api/hls/master.m3u8",
    contentType: "live",
    _playbackMountedAt: 0,
    playbackSessionId: 0,
    playbackMetrics: new PlaybackSession({ now: timerApi.now }),
    playerUIController: {
      showLoading() {},
      hideLoading() {},
      showRecovery() {},
      hideAutoplayBlocked() {},
      hideEndedOverlay() {},
      showError: (msg) => calls.push(msg),
    },
    startupPresentation: { stop() {}, recover() {} },
    cleanup() {
      this.playbackSessionId++;
      calls.push("cleanup");
    },
    beginPlaybackSession() {
      return ++this.playbackSessionId;
    },
    getEffectiveUrl: () => "/api/hls/master.m3u8",
    isPaused: () => false,
    getCurrentTime: () => 0,
    ensureStreamLoader() {},
    pushEventSafe: (event, payload) => calls.push([event, payload]),
    reportPlayerLifecycle() {},
    isPiPSupported: () => false,
    buildEngineContext: () => ({ capabilities: {} }),
    reportPlayerDebug() {},
    playbackEngineActivation: { activate: () => calls.push("activated") },
    setPlaybackSystemState() {},
  });
  hook.initRecoveryGuard();
  return { hook, calls, timerApi, productionHook: bindings.hook };
}

test("automatic restarts retain TTFF origin and the global deadline; terminal callbacks cannot restart", () => {
  const { hook, calls, timerApi } = harness();
  timerApi.advance(200);
  hook.initPlayer();
  const batch = hook.playbackMetrics.active.batchId;
  timerApi.advance(1000);
  hook.initPlayer();
  assert.equal(hook.playbackMetrics.active.batchId, batch);
  assert.equal(hook.playbackMetrics.active.startedAt, 0);
  timerApi.advance(28800);
  assert.equal(hook._terminalPlaybackError, true);
  const activations = calls.filter((call) => call === "activated").length;
  hook.initPlayer();
  assert.equal(calls.filter((call) => call === "activated").length, activations);
  const payload = calls.find((call) => Array.isArray(call) && call[0] === "client_telemetry")[1];
  assert.equal(payload.outcome, "error");
  assert.equal(payload.end_reason, "startup_deadline");
  assert.equal(payload.ttff_ms, undefined);
});

test("a terminal error emits its session immediately and cannot later become cancelled", () => {
  const { hook, calls, timerApi } = harness();
  hook.initPlayer();
  hook.playbackMetrics.selectEngine("avplayer");
  timerApi.advance(1200);
  hook.showPlaybackError("Synthetic terminal failure");
  const samples = () =>
    calls.filter((call) => Array.isArray(call) && call[0] === "client_telemetry");
  assert.equal(samples().length, 1);
  assert.equal(samples()[0][1].outcome, "error");
  assert.equal(samples()[0][1].engine, "avplayer");
  assert.equal(samples()[0][1].ttff_ms, undefined);
  assert.equal(samples()[0][1].session_duration_ms, 1200);
  hook.flushPlaybackMetrics("cancelled");
  timerApi.advance(30000);
  assert.equal(samples().length, 1, "unmount/deadline cannot duplicate the terminal sample");
  hook.recoveryGuard.destroy();
});

test("manual retry starts a fresh session without relabeling the previous terminal error", () => {
  const { hook, calls, timerApi } = harness();
  hook.initPlayer();
  const firstBatch = hook.playbackMetrics.active.batchId;
  timerApi.advance(500);
  hook.showPlaybackError("Synthetic terminal failure");
  hook.startupPresentation.begin = () => {};
  hook.retryPlaybackFromError();
  assert.notEqual(hook.playbackMetrics.active.batchId, firstBatch);
  timerApi.advance(500);
  hook.playbackMetrics.markFirstFrame();
  hook.flushPlaybackMetrics("cancelled");
  const samples = calls
    .filter((call) => Array.isArray(call) && call[0] === "client_telemetry")
    .map((call) => call[1]);
  assert.deepEqual(
    samples.map((sample) => sample.outcome),
    ["error", "cancelled"],
  );
  assert.equal(samples[0].batch_id, firstBatch);
  assert.equal(samples[1].ttff_ms, 500);
  hook.recoveryGuard.destroy();
});

test("recovery deadline emits one error after twenty seconds while retaining the first frame", () => {
  const { hook, calls, timerApi } = harness();
  hook.initPlayer();
  timerApi.advance(1000);
  hook.playbackMetrics.markFirstFrame();
  hook.recoveryGuard.playing();
  hook.recoveryGuard.attempt();
  timerApi.advance(19999);
  assert.equal(
    calls.filter((call) => Array.isArray(call) && call[0] === "client_telemetry").length,
    0,
  );
  timerApi.advance(1);
  const samples = calls.filter((call) => Array.isArray(call) && call[0] === "client_telemetry");
  assert.equal(samples.length, 1);
  assert.equal(samples[0][1].outcome, "error");
  assert.equal(samples[0][1].end_reason, "recovery_deadline");
  assert.equal(samples[0][1].ttff_ms, 1000);
  assert.equal(samples[0][1].session_duration_ms, 21000);
});

test("all native-element engines preserve retry budgets until 20 seconds of stable playback", () => {
  for (const engine of [ENGINE_ID.NATIVE, ENGINE_ID.HLS, ENGINE_ID.MPEGTS]) {
    const { hook, timerApi } = harness();
    let resets = 0;
    hook.hlsRecoveryCoordinator = { reset: () => resets++ };
    hook.mpegtsRecoveryCoordinator = { reset: () => resets++ };
    hook.mediaElementEngine = { id: engine };
    hook.startupPresentation = { hasFrame: true, awaitingFrame: false, recover() {} };
    hook.recoveryGuard.attempt();
    hook.handlePlaybackStarted();
    timerApi.advance(19999);
    assert.equal(resets, 0);
    hook.handlePlaybackStarted();
    timerApi.advance(1);
    assert.equal(resets, 2);
    hook.recoveryGuard.destroy();
  }
});

test("watch-party hold suspends deadlines even before a video has started", () => {
  const { hook, timerApi } = harness();
  hook.watchPartyPolicy = {
    setSyncHold() {
      return true;
    },
    isViewer: true,
  };
  hook.setWatchPartySyncHold(true);
  timerApi.advance(100000);
  assert.equal(hook._terminalPlaybackError, undefined);
  hook.setWatchPartySyncHold(false);
  timerApi.advance(30000);
  assert.equal(hook._terminalPlaybackError, true);
});

test("normal startup waiting keeps preparation copy, while post-frame waiting announces recovery", () => {
  const { hook } = harness();
  let recoveries = 0;
  hook.startupPresentation = { hasFrame: false, recover: () => recoveries++ };
  hook.observePlaybackState(PLAYBACK_STATE.STALLED, "media_waiting");
  assert.equal(recoveries, 0);
  hook.startupPresentation.hasFrame = true;
  hook.observePlaybackState(PLAYBACK_STATE.STALLED, "media_waiting");
  assert.equal(recoveries, 1);
  hook.recoveryGuard.destroy();
});

test("source failover enters recovery immediately and cannot reset budget while waiting for server", () => {
  const { hook, timerApi } = harness();
  let resets = 0;
  let reconnecting = 0;
  hook.hlsRecoveryCoordinator = { reset: () => resets++ };
  hook.sourceFailoverController = { request: () => true };
  hook.startupPresentation = {
    hasFrame: true,
    awaitingFrame: false,
    recover: () => reconnecting++,
    stop() {},
  };
  hook.recoveryGuard.playing();
  timerApi.advance(19000);
  hook.showPlaybackError("network");
  assert.equal(reconnecting, 1);
  timerApi.advance(1000);
  assert.equal(resets, 0);
  timerApi.advance(19000);
  assert.equal(hook._terminalPlaybackError, true);
});

test("avbridge waits on the shared video frame callback, like native/HLS/mpegts", () => {
  const { hook, productionHook } = harness();
  const selected = [];
  hook.startupPresentation = { attach: (options) => selected.push(options.native) };
  productionHook.reportPlayerLifecycle.call(hook, "player_engine_selected", { engine: "avbridge" });
  assert.deepEqual(selected, [true]);
  hook.recoveryGuard.destroy();
});

test("server provider overrides click context and source failover cannot reuse the old provider memory", () => {
  const { hook, calls } = harness({ intent: { providerId: "3" }, streamType: "mp4" });
  hook.el.dataset.providerId = "4";
  hook.initStartupPresentation();
  hook.initPlayer();
  assert.ok(calls.some((call) => call[0] === "recommendation" && call[1] === "provider:4:mp4"));
  hook.applySourceFailover({
    stream_url: "/api/stream/vod.mp4",
    content_id: 11,
    provider_id: 6,
    stream_type: "mp4",
  });
  assert.equal(hook.providerId, "6");
  assert.equal(hook.el.dataset.providerId, "6");
  assert.ok(calls.some((call) => call[0] === "recommendation" && call[1] === "provider:6:mp4"));
  hook.applySourceFailover({
    stream_url: "/api/stream/vod.mp4",
    content_id: 12,
    stream_type: "mp4",
  });
  assert.equal(hook.providerId, null);
  assert.equal(hook.el.dataset.providerId, "");
  assert.deepEqual(calls.filter((call) => call[0] === "recommendation").at(-1), [
    "recommendation",
    null,
  ]);
  hook.recoveryGuard.destroy();
});

test("an identified click supplies the provider when the server mount omits it", () => {
  const { hook } = harness({ intent: { providerId: "3" } });
  hook.initStartupPresentation();
  assert.equal(hook.providerId, "3");
  hook.recoveryGuard.destroy();
});

test("hook learns native and AVPlayer only after their presented frame and stable window, preserving explanation", () => {
  const { hook, calls, timerApi, productionHook } = harness({ streamType: "mp4" });
  let position = 0;
  hook.getCurrentTime = () => position;
  hook.el.dataset.providerId = "3";
  hook.clientRevision = "d".repeat(40);
  hook.initStartupPresentation();
  hook.initPlayer();
  productionHook.reportPlayerLifecycle.call(hook, "player_engine_selected", { engine: "native" });
  timerApi.advance(1000);
  assert.equal(calls.filter((call) => call[0] === "memory_success").length, 0);
  hook.startupPresentation.options.onFrame();
  position = 5;
  timerApi.advance(5000);
  const learned = () => calls.filter((call) => call[0] === "memory_success");
  assert.equal(learned().length, 1);
  assert.equal(learned()[0][1], "provider:3:mp4");
  assert.equal(learned()[0][2], "native");
  productionHook.reportPlayerLifecycle.call(hook, "player_engine_selected", {
    engine: "avplayer",
    fallback: true,
    reason: "fallback_audio",
  });
  position = 10;
  timerApi.advance(5000);
  assert.equal(learned().length, 1, "new engine needs its own presented frame");
  hook.startupPresentation.options.onFrame();
  position = 15;
  timerApi.advance(5000);
  assert.equal(learned().length, 2);
  assert.equal(learned()[1][2], "avplayer");
  hook.flushPlaybackMetrics("cancelled");
  const payload = calls.find((call) => Array.isArray(call) && call[0] === "client_telemetry")[1];
  assert.equal(payload.engine_reason, "fallback_audio");
  assert.equal(payload.end_reason, "first_frame_then_user_left");
  assert.equal(payload.client_revision, "d".repeat(40));
  hook.providerEngineMemory.clear();
  hook.recoveryGuard.destroy();
});

test("retry exhaustion carries its bounded reason even without an engine exception", () => {
  const { hook, calls } = harness();
  hook.initPlayer();
  for (let n = 0; n < 7; n++) hook.initPlayer();
  const samples = calls.filter((call) => Array.isArray(call) && call[0] === "client_telemetry");
  assert.equal(samples.length, 1);
  assert.equal(samples[0][1].end_reason, "retry_budget");
  assert.equal(samples[0][1].error_count, 0);
});

test("overlapping managed seeks require a new presented frame and stale seek completion cannot affect a new engine", () => {
  const { hook, calls, timerApi, productionHook } = harness({ streamType: "mp4" });
  let position = 0;
  hook.getCurrentTime = () => position;
  hook.el.dataset.providerId = "3";
  hook.initStartupPresentation();
  hook.initPlayer();
  productionHook.reportPlayerLifecycle.call(hook, "player_engine_selected", { engine: "avplayer" });
  hook.startupPresentation.options.onFrame();
  const first = hook.beginMemorySeek();
  const second = hook.beginMemorySeek();
  first();
  assert.equal(hook._memorySeekTokens.size, 1);
  position = 30;
  hook.startupPresentation.options.onFrame();
  timerApi.advance(5000);
  assert.equal(calls.filter((call) => call[0] === "memory_success").length, 0);
  second();
  hook.providerEngineMemory.progress();
  position = 35;
  timerApi.advance(5000);
  assert.equal(
    calls.filter((call) => call[0] === "memory_success").length,
    0,
    "post-seek frame still required",
  );
  hook.startupPresentation.options.onFrame();
  position = 40;
  timerApi.advance(5000);
  assert.equal(calls.filter((call) => call[0] === "memory_success").length, 1);
  const stale = hook.beginMemorySeek();
  productionHook.reportPlayerLifecycle.call(hook, "player_engine_selected", { engine: "native" });
  const current = hook.beginMemorySeek();
  stale();
  assert.equal(hook._memorySeekTokens.size, 1);
  current();
  hook.providerEngineMemory.clear();
  hook.recoveryGuard.destroy();
});
