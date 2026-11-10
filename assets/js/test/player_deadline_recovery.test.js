import assert from "node:assert/strict";
import test from "node:test";
import VideoPlayer from "../hooks/video_player.js";
import {
  AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS,
  createAvPlayerEngineActivation,
} from "../player/avplayer_engine_activation.js";
import { selectEngineDecision } from "../player/engine_selector.js";
import { PlaybackRecoveryGuard } from "../player/playback_recovery_guard.js";
import { PlaybackSession } from "../player/playback_session.js";
import { getRecommendedPlayer, recordPlayerSuccess } from "../player/player_preferences.js";
import { clock } from "./support/playback_clock.js";

function harness(t, streamType = "mp4") {
  const values = new Map();
  const old = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key) => values.get(key) ?? null,
      setItem: (k, v) => values.set(k, v),
      removeItem: (k) => values.delete(k),
    },
  });
  t.after(() =>
    old ? Object.defineProperty(globalThis, "localStorage", old) : delete globalThis.localStorage,
  );
  const key = `provider:3:${streamType}`;
  recordPlayerSuccess(key, "avplayer");
  recordPlayerSuccess(key, "avplayer");
  const timerApi = clock();
  const metrics = new PlaybackSession({ now: timerApi.now });
  metrics.begin({ streamType, contentType: "vod" });
  metrics.selectEngine("avplayer", "provider_memory");
  const hook = Object.assign({}, VideoPlayer, {
    providerId: "3",
    currentStreamType: streamType,
    contentType: "vod",
    _selectedEngine: "avplayer",
    avPlayerEngineActivation: createAvPlayerEngineActivation({
      host: {
        ...Object.fromEntries(
          AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS.map((name) => [name, () => {}]),
        ),
        getProviderId: () => "3",
        getStreamType: () => streamType,
      },
    }),
    fallbackAttempts: 0,
    playbackSessionId: 1,
    playbackMetrics: metrics,
    cleanup() {
      this.playbackSessionId++;
    },
    initPlaybackEngineTransitionController() {
      this.replaced = true;
    },
    initPlayer(options) {
      this.activation = options;
      this.reportPlayerLifecycle("player_engine_selected", {
        engine: options.forcedEngine,
        fallback: options.fallback,
        reason: "failover",
      });
    },
    pushEventSafe() {},
  });
  const reasons = [];
  const guard = new PlaybackRecoveryGuard({
    timerApi,
    now: timerApi.now,
    onStartupDeadline: () => hook.recoverStartupDeadline(),
    onExhausted: (r) => reasons.push(r),
  });
  hook.recoveryGuard = guard;
  guard.begin();
  guard.bootstrap();
  return { hook, guard, timerApi, metrics, reasons, key };
}

test("real hook deadline recovers MP4 once, clears persisted evidence and reports failover", (t) => {
  const h = harness(t);
  h.timerApi.advance(60000);
  assert.equal(h.hook.activation.forcedEngine, "native");
  assert.equal(h.hook.avPlayerAttempted, true);
  assert.equal(h.hook.replaced, true);
  assert.equal(getRecommendedPlayer(h.key), null);
  assert.equal(
    selectEngineDecision({ streamType: "mp4", recommendedPlayer: getRecommendedPlayer(h.key) })
      .engine,
    "native",
  );
  h.timerApi.advance(20000);
  assert.deepEqual(h.reasons, ["recovery_deadline"]);
  const sample = h.metrics.finish("error", h.reasons[0]);
  assert.equal(sample.fallback_count, 1);
  assert.equal(sample.engine_reason, "failover");
  assert.equal(sample.end_reason, "recovery_deadline");
  assert.equal(sample.ttff_ms, undefined);
});

test("MKV bootstrap timeout remains terminal and forgets failed AV memory for manual retry", (t) => {
  const h = harness(t, "mkv");
  h.timerApi.advance(60000);
  assert.equal(h.hook.activation, undefined);
  assert.equal(getRecommendedPlayer(h.key), null);
  assert.deepEqual(h.reasons, ["startup_deadline"]);
});

test("native first frame completes recovery without later terminal callbacks", (t) => {
  const h = harness(t);
  h.timerApi.advance(55000);
  h.guard.awaitFrame();
  h.timerApi.advance(30000);
  h.timerApi.advance(5000);
  h.guard.playing();
  h.metrics.markFirstFrame();
  h.timerApi.advance(100000);
  assert.deepEqual(h.reasons, []);
  assert.equal(h.metrics.finish("cancelled").fallback_count, 1);
});
