import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const coordinatorUrl = new URL("../player/mpegts_recovery_coordinator.js", import.meta.url);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const stateUrl = new URL("../player/player_state.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("the MPEG-TS coordinator is independent from the hook and concrete fallback engines", async () => {
  const coordinator = await source(coordinatorUrl);

  assert.match(coordinator, /from "\.\/mpegts_error_policy\.js"/);
  assert.doesNotMatch(coordinator, /video_player|phoenix|live_view/i);
  assert.doesNotMatch(
    coordinator,
    /AVPlayerWrapper|NativePlaybackEngine|HlsPlaybackEngine|MpegtsWrapper/,
  );
});

test("VideoPlayer delegates MPEG-TS retry state while retaining product fallbacks", async () => {
  const hook = await source(hookUrl);

  assert.match(hook, /createMpegtsRecoveryCoordinator.*mpegts_recovery_coordinator\.js/s);
  assert.doesNotMatch(hook, /classifyMpegtsError|executeMpegtsDecision|cancelMpegtsRetry/);
  assert.doesNotMatch(hook, /_mpegtsRecoveryPromise|_mpegtsRecoverySessionId|_mpegtsRetryTimer/);
  assert.doesNotMatch(hook, /this\.mpegtsNetworkAttempts|this\.mpegtsRecreateAttempts/);

  for (const callback of ["retryDirect", "retryMpegts", "fallbackAVPlayer", "fallbackNative"]) {
    assert.match(hook, new RegExp(`${callback}:`));
  }
});

test("the initial hook state no longer owns MPEG-TS recovery internals", async () => {
  const state = await source(stateUrl);

  assert.doesNotMatch(
    state,
    /mpegtsNetworkAttempts|mpegtsRecreateAttempts|mpegtsRecoveryPromise|mpegtsRecoverySessionId|mpegtsRetryTimer/,
  );
});
