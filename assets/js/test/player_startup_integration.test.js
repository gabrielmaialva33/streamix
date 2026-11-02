import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { ENGINE_ID, PLAYBACK_STATE } from "../player/engine_contract.js";
import { PlaybackRecoveryGuard } from "../player/playback_recovery_guard.js";
import { PlaybackSession } from "../player/playback_session.js";
import { clock } from "./support/playback_clock.js";

// Execute the production hook methods with browser/transport boundaries supplied explicitly.
const source = readFileSync(new URL("../hooks/video_player.js", import.meta.url), "utf8")
  .replace(/^import[\s\S]*?;\n/gm, "")
  .replace("export default VideoPlayer;", "globalThis.hook = VideoPlayer;");
function harness() {
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
    resolveStreamType: () => "hls",
    getCapabilitySummary: () => ({}),
    isStandalonePwa: () => false,
    getRecommendedPlayer: () => null,
    selectEngine: () => "native",
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
  assert.equal(payload.ttff_ms, undefined);
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
