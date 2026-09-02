import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const coordinatorUrl = new URL("../player/mpegts_recovery_coordinator.js", import.meta.url);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const stateUrl = new URL("../player/player_state.js", import.meta.url);
const activationUrl = new URL("../player/mpegts_engine_activation.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

function methodSource(sourceText, name) {
  const start = [`  ${name}(`, `  async ${name}(`]
    .map((signature) => sourceText.indexOf(signature))
    .find((position) => position >= 0);
  assert.ok(start >= 0, `missing ${name}()`);

  const openingBrace = sourceText.indexOf("{", start);
  let depth = 0;
  let quote = null;
  let escaped = false;

  for (let index = openingBrace; index < sourceText.length; index += 1) {
    const character = sourceText[index];

    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = null;
      continue;
    }

    if (character === '"' || character === "'" || character === "`") quote = character;
    else if (character === "{") depth += 1;
    else if (character === "}") depth -= 1;
    if (depth === 0) return sourceText.slice(start, index + 1);
  }

  assert.fail(`unbalanced ${name}()`);
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

test("MPEG-TS recovery is reset by confirmed playback, not by the initial play request", async () => {
  const [hook, activation] = await Promise.all([source(hookUrl), source(activationUrl)]);
  const listeners = methodSource(hook, "setupEventListeners");
  const loadMpegts = activation.slice(activation.indexOf("  async load("));

  assert.match(
    hook,
    /markMpegtsRecovered: \(\) => this\.mpegtsRecoveryCoordinator\?\.markRecovered\(\)/,
  );
  const playListener = listeners.slice(
    listeners.indexOf('listenOptional(this.video, "play"'),
    listeners.indexOf('listenOptional(this.video, "pause"'),
  );
  const playingListener = listeners.slice(
    listeners.lastIndexOf('listenOptional(this.video, "playing"'),
    listeners.indexOf('listenOptional(this.video, "canplaythrough"'),
  );

  assert.doesNotMatch(playListener, /handlePlaybackStarted/);
  assert.match(playingListener, /handlePlaybackStarted/);
  assert.match(loadMpegts, /onPlaying[\s\S]*this\.host\.markMpegtsRecovered\(\)/);
  assert.doesNotMatch(loadMpegts, /_mpegtsNetworkAttempts|_mpegtsRecreateAttempts/);
});
