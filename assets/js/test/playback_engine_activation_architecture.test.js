import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const coordinatorUrl = new URL("../player/playback_engine_activation.js", import.meta.url);
const hlsActivationUrl = new URL("../player/hls_engine_activation.js", import.meta.url);
const mpegtsActivationUrl = new URL("../player/mpegts_engine_activation.js", import.meta.url);
const playerStateUrl = new URL("../player/player_state.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

function compact(text) {
  return text.replace(/\s+/g, " ").trim();
}

function methodIndex(hook, methodName, fromIndex = 0) {
  const indexes = [`  ${methodName}(`, `  async ${methodName}(`]
    .map((signature) => hook.indexOf(signature, fromIndex))
    .filter((index) => index >= 0);
  return indexes.length > 0 ? Math.min(...indexes) : -1;
}

function methodSlice(hook, methodName, nextMethodName) {
  const start = methodIndex(hook, methodName);
  const end = methodIndex(hook, nextMethodName, start + 1);
  assert.notEqual(start, -1, `missing ${methodName}()`);
  assert.notEqual(end, -1, `missing boundary after ${methodName}()`);
  return hook.slice(start, end);
}

test("VideoPlayer composes one engine activation coordinator behind an explicit host", async () => {
  const [hook, playerState] = await Promise.all([source(hookUrl), source(playerStateUrl)]);
  const normalized = compact(hook);

  assert.match(
    hook,
    /import \{ createPlaybackEngineActivation \} from "\.\.\/player\/playback_engine_activation\.js";/,
  );
  assert.match(
    hook,
    /import \{ createHlsEngineActivation \} from "\.\.\/player\/hls_engine_activation\.js";/,
  );
  assert.match(
    hook,
    /createMpegtsEngineActivation,[\s\S]*from "\.\.\/player\/mpegts_engine_activation\.js";/,
  );
  assert.ok(
    normalized.includes(
      "this.initPlaybackBrowserIntegration(); this.updateVolumeUI(); this.initPlaybackEngineActivation(); this.setupEventListeners();",
    ),
  );
  assert.match(
    hook,
    /initPlaybackEngineActivation\(\) \{[\s\S]*createPlaybackEngineActivation\(\{/,
  );
  assert.match(hook, /const host = this\.buildPlaybackEngineActivationHost\(\);/);
  assert.match(
    hook,
    /this\.playbackEngineActivation\?\.destroy\(\);\s*this\.playbackEngineActivation = null;/,
  );
  assert.match(playerState, /playbackEngineActivation: null/);

  for (const selection of [
    "HLS_JS",
    "MPEGTS",
    "MPEGTS_FLV",
    "NATIVE",
    "AVPLAYER",
    "AVBRIDGE",
    "H265WEB",
    "FLV_UNSUPPORTED",
  ]) {
    assert.match(
      hook,
      new RegExp(`\\[ENGINE_SELECTION\\.${selection}\\]:`),
      `activation coordinator must register ${selection}`,
    );
  }
});

test("initPlayer dispatches every engine decision through the coordinator", async () => {
  const hook = await source(hookUrl);
  const initPlayer = methodSlice(hook, "initPlayer", "logHlsRecoveryDecision");

  assert.match(
    initPlayer,
    /void this\.playbackEngineActivation\.activate\(engine, \{ sessionId \}\);/,
  );
  assert.doesNotMatch(initPlayer, /switch \(engine\)|case "/);
  assert.doesNotMatch(
    initPlayer,
    /playWithHls\(|playWithMpegts\(|playWithAvbridge\(|playWithH265web\(|playNative\(|startWithAVPlayer\(/,
  );
});

test("extracted engine entrypoints stay thin compatibility delegates on the hook", async () => {
  const hook = await source(hookUrl);
  const normalized = compact(hook);

  for (const delegate of [
    "playWithHls() { return ( this.playbackEngineActivation?.activate(ENGINE_SELECTION.HLS_JS) ?? Promise.resolve(false) ); }",
    'playWithMpegts(type = "mpegts") { const selection = type === "flv" ? ENGINE_SELECTION.MPEGTS_FLV : ENGINE_SELECTION.MPEGTS; return this.playbackEngineActivation?.activate(selection) ?? Promise.resolve(false); }',
    "activateHlsEngineFromLoader(sessionId = this.playbackSessionId, loader = this.streamLoader) { return ( this.playbackEngineActivation ?.get(ENGINE_SELECTION.HLS_JS) ?.adoptLoaderEngine(sessionId, loader) ?? null ); }",
  ]) {
    assert.ok(normalized.includes(delegate), `missing thin activation delegate: ${delegate}`);
  }

  for (const leakedActivation of [
    "guardPlaybackLoad",
    "loader.loadHls(",
    "loader.loadMpegts(",
    "loadMpegtsForTransition",
    "getHlsEngine?.()",
    "getMpegtsEngine()",
    "HLS nao suportado neste navegador",
    "startup-mpegts",
    "MPEG-TS transition completed without an engine",
    "HLS engine was not registered by StreamLoader",
  ]) {
    assert.equal(
      hook.includes(leakedActivation),
      false,
      `${leakedActivation} must remain owned by an engine activation module`,
    );
  }
});

test("the coordinator owns dispatch without knowing concrete engines or the DOM", async () => {
  const coordinator = await source(coordinatorUrl);

  assert.match(coordinator, /export class PlaybackEngineActivation/);
  assert.match(coordinator, /PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS/);
  assert.match(coordinator, /export function assertActivationHost/);
  assert.match(coordinator, /fallbackSelection = ENGINE_SELECTION\.NATIVE/);
  assert.match(coordinator, /this\.host\.isSessionCurrent\(request\.sessionId\)/);
  assert.doesNotMatch(
    coordinator,
    /AVPlayerWrapper|HlsPlaybackEngine|MpegtsPlaybackEngine|StreamLoader|hls\.js|mpegts\.js|H265web|Avbridge/,
  );
  assert.doesNotMatch(
    coordinator,
    /document\.|window\.|querySelector|Phoenix|LiveSocket|pushEvent/,
  );
  assert.doesNotMatch(coordinator, /hooks\/video_player/);
});

test("engine activations consume the host contract and never reach for the hook or Phoenix", async () => {
  const activations = await Promise.all([source(hlsActivationUrl), source(mpegtsActivationUrl)]);

  for (const activation of activations) {
    assert.match(activation, /assertActivationHost\(/);
    assert.match(activation, /PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS/);
    assert.match(activation, /_HOST_METHODS = Object\.freeze\(\[/);
    assert.doesNotMatch(activation, /hooks\/video_player|Phoenix|LiveSocket|pushEvent|handleEvent/);
    assert.doesNotMatch(activation, /document\.|window\.|querySelector/);
    assert.doesNotMatch(
      activation,
      /this\.video\b|this\.el\b|this\.streamLoader\b|this\.playbackSessionId\b/,
    );
    assert.doesNotMatch(
      activation,
      /new Hls\(|createHlsPlaybackEngine\(|createMpegtsPlaybackEngine\(/,
    );
  }

  const [hls, mpegts] = activations;
  assert.match(hls, /activate\(ENGINE_SELECTION\.NATIVE, \{ sessionId/);
  assert.match(mpegts, /this\.host\.getTransitionController\(\)/);
  assert.match(mpegts, /this\.host\.recoverFromMpegtsError\(/);
  assert.doesNotMatch(mpegts, /PlaybackEngineTransitionController\(/);
});
