import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const coordinatorUrl = new URL("../player/playback_engine_activation.js", import.meta.url);
const hlsActivationUrl = new URL("../player/hls_engine_activation.js", import.meta.url);
const mpegtsActivationUrl = new URL("../player/mpegts_engine_activation.js", import.meta.url);
const nativeActivationUrl = new URL("../player/native_engine_activation.js", import.meta.url);
const avPlayerActivationUrl = new URL("../player/avplayer_engine_activation.js", import.meta.url);
const canvasActivationUrl = new URL("../player/canvas_engine_activation.js", import.meta.url);
const avbridgeActivationUrl = new URL("../player/avbridge_engine_activation.js", import.meta.url);
const h265webActivationUrl = new URL("../player/h265web_engine_activation.js", import.meta.url);
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
  assert.match(
    hook,
    /import \{ createNativeEngineActivation \} from "\.\.\/player\/native_engine_activation\.js";/,
  );
  assert.match(hook, /this\.nativeEngineActivation = createNativeEngineActivation\(\{ host \}\);/);
  assert.match(hook, /\[ENGINE_SELECTION\.NATIVE\]: this\.nativeEngineActivation,/);
  assert.match(
    hook,
    /import \{ createAvPlayerEngineActivation \} from "\.\.\/player\/avplayer_engine_activation\.js";/,
  );
  assert.match(
    hook,
    /this\.avPlayerEngineActivation = createAvPlayerEngineActivation\(\{ host \}\);/,
  );
  assert.match(hook, /\[ENGINE_SELECTION\.AVPLAYER\]: this\.avPlayerEngineActivation,/);
  assert.match(playerState, /avPlayerEngineActivation: null/);
  assert.doesNotMatch(playerState, /avPlayerTimeInterval/);
  assert.match(
    hook,
    /import \{ createAvbridgeEngineActivation \} from "\.\.\/player\/avbridge_engine_activation\.js";/,
  );
  assert.match(
    hook,
    /import \{ createH265webEngineActivation \} from "\.\.\/player\/h265web_engine_activation\.js";/,
  );
  assert.match(hook, /\[ENGINE_SELECTION\.AVBRIDGE\]: this\.avbridgeEngineActivation,/);
  assert.match(hook, /\[ENGINE_SELECTION\.H265WEB\]: this\.h265webEngineActivation,/);
  assert.match(playerState, /avbridgeEngineActivation: null/);
  assert.match(playerState, /h265webEngineActivation: null/);
  assert.doesNotMatch(playerState, /h265webTimeInterval/);
  assert.match(playerState, /nativeEngineActivation: null/);
  assert.doesNotMatch(playerState, /audioCheckTimeout/);
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
  const initPlayer = methodSlice(hook, "initPlayer", "buildEngineRecoveryHost");

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
    "playNative() { return ( this.playbackEngineActivation?.activate(ENGINE_SELECTION.NATIVE) ?? Promise.resolve(false) ); }",
    "playNativeAfterResume(sessionId, resumeTime) { return this.nativeEngineActivation?.playAfterResume(sessionId, resumeTime) ?? Promise.resolve(); }",
    "startWithAVPlayer(sessionId) { return ( this.playbackEngineActivation?.activate(ENGINE_SELECTION.AVPLAYER, { sessionId }) ?? Promise.resolve(false) ); }",
    "tryAVPlayerFallback() { return this.avPlayerEngineActivation?.tryFallback() ?? Promise.resolve(false); }",
    "switchToAVPlayerWithTrack(trackType, trackIndex, seekTime, shouldPlay) { return ( this.avPlayerEngineActivation?.switchWithTrack(trackType, trackIndex, seekTime, shouldPlay) ?? Promise.resolve(false) ); }",
    "stopAVPlayerTimeUpdates() { return this.avPlayerEngineActivation?.stopTimeUpdates() ?? false; }",
    "playWithAvbridge() { return ( this.playbackEngineActivation?.activate(ENGINE_SELECTION.AVBRIDGE) ?? Promise.resolve(false) ); }",
    "playWithH265web() { return ( this.playbackEngineActivation?.activate(ENGINE_SELECTION.H265WEB) ?? Promise.resolve(false) ); }",
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
    "new NativeBufferManager",
    'from "../media/native_buffer"',
    "createNativePlaybackEngine",
    "createMediaElementEngine",
    "detectAudioIssue",
    "native_source_attached",
    "canTryAVPlayerForCurrentVod",
    "shouldCheckNativeAudio",
    "traceNativeLifecycle",
    "audioCheckTimeout",
    "_nativeErrorHandler",
    'recordPlayerSuccess(contentKey, "native"',
    "new AVPlayerWrapper",
    "loadAVPlayer",
    "startup-avplayer",
    "native-to-avplayer-fallback",
    "avplayer-to-native-recovery",
    "requestAnimationFrame",
    "resolvePlaybackResumeTime",
    "forgetRecommendedPlayer",
    "buildAVPlayerLoadOptions",
    "detectAVPlayerTracks",
    "transitionNativeToAVPlayer",
    "transitionFromFailedAVPlayer",
    "id: ENGINE_ID.AVPLAYER",
    "loadAvbridge",
    "loadH265web",
    "new AvbridgeWrapper",
    "new H265webWrapper",
    "createPlaybackTickThrottle",
    "id: ENGINE_ID.AVBRIDGE",
    "id: ENGINE_ID.H265WEB",
    'reportPlayerLifecycle("player_engine_fallback"',
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
  const activations = await Promise.all([
    source(hlsActivationUrl),
    source(mpegtsActivationUrl),
    source(nativeActivationUrl),
    source(avPlayerActivationUrl),
    source(canvasActivationUrl),
    source(avbridgeActivationUrl),
    source(h265webActivationUrl),
  ]);

  for (const activation of activations) {
    assert.ok(
      /assertActivationHost\(/.test(activation) ||
        /extends CanvasEngineActivation/.test(activation),
      "every activation validates its host directly or through the canvas base",
    );
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

  const [hls, mpegts, native, avplayer, canvas, avbridge, h265web] = activations;
  assert.match(hls, /activate\(ENGINE_SELECTION\.NATIVE, \{ sessionId/);
  assert.match(mpegts, /this\.host\.getTransitionController\(\)/);
  assert.match(mpegts, /this\.host\.recoverFromMpegtsError\(/);
  assert.doesNotMatch(mpegts, /PlaybackEngineTransitionController\(/);
  assert.match(native, /this\.deps\.createNativePlaybackEngine\(\{/);
  assert.match(native, /this\.host\.tryAVPlayerFallback\(\)/);
  assert.match(native, /this\.deps\.loadAVPlayer\(\)/);
  assert.doesNotMatch(native, /AVPlayerWrapper|transitionNativeToAVPlayer|MediaError\./);
  assert.match(avplayer, /this\.host\.getTransitionController\(\)/);
  assert.match(avplayer, /this\.host\.canAttemptFallback\(\)/);
  assert.match(avplayer, /this\.deps\.loadAVPlayer\(\)/);
  assert.match(avplayer, /this\.host\.teardownAVPlayer\(/);
  assert.match(
    avplayer,
    /this\.deps\.createAvPlayerPlaybackEngine\(\{ AVPlayerWrapper, container: mount \}\)/,
  );
  assert.match(
    avplayer,
    /avPlayer\.on\(ENGINE_EVENT\.(READY|PLAYING|PAUSED|ERROR|TIME_UPDATE|ENDED),/,
  );
  assert.doesNotMatch(avplayer, /new AVPlayerWrapper\(|onPlay:|onPause:|onEnded:|onTimeUpdate:/);
  assert.doesNotMatch(
    avplayer,
    /evaluateFallbackAttempt|PlaybackEngineTeardownQueue|new PlaybackEngineTransitionController/,
  );
  assert.match(canvas, /export class CanvasEngineActivation/);
  assert.match(canvas, /this\.host\.tryAVPlayerFallback\(\)/);
  assert.match(canvas, /player_engine_fallback/);
  assert.match(avbridge, /extends CanvasEngineActivation/);
  assert.match(avbridge, /this\.deps\.loadAvbridge\(\)/);
  assert.match(h265web, /extends CanvasEngineActivation/);
  assert.match(h265web, /this\.deps\.loadH265web\(\)/);
  assert.match(h265web, /this\.host\.getH265webMount\(\)/);
});

test("every host callback of the activation host resolves to a method the hook still defines", async () => {
  const hook = await source(hookUrl);
  const start = hook.indexOf("  buildPlaybackEngineActivationHost() {");
  const end = hook.indexOf("  initPlaybackEngineActivation() {", start);
  assert.ok(start >= 0 && end > start, "host builder must exist before the activation wiring");

  const hostBuilder = hook.slice(start, end);
  const referenced = new Set(
    [...hostBuilder.matchAll(/this\.([A-Za-z_$][\w$]*)\(/g)].map((match) => match[1]),
  );
  assert.ok(referenced.size >= 15, "host builder must delegate to hook methods");

  for (const name of referenced) {
    const defined = new RegExp(`^  (?:async )?${name}\\(`, "m").test(hook);
    assert.ok(
      defined,
      `activation host references this.${name}() but the hook no longer defines it`,
    );
  }
});

test("the hook no longer constructs any concrete playback engine", async () => {
  const hook = await source(hookUrl);
  const start = hook.indexOf("  initPlaybackEngineActivation() {");
  const end = hook.indexOf("  setupNetworkMonitor() {", start);
  assert.ok(start >= 0 && end > start);
  const wiring = hook.slice(start, end);

  for (const selection of [
    "HLS_JS",
    "MPEGTS",
    "MPEGTS_FLV",
    "NATIVE",
    "AVPLAYER",
    "AVBRIDGE",
    "H265WEB",
  ]) {
    const registration = new RegExp(
      `\\[ENGINE_SELECTION\\.${selection}\\]: (?:this\\.\\w+EngineActivation|\\w+Activation|create\\w+EngineActivation\\(\\{ host \\}\\)),`,
    );
    assert.match(
      wiring,
      registration,
      `${selection} must be registered as an activation instance, not a hook delegate`,
    );
  }

  assert.doesNotMatch(hook, /new \w+Wrapper\(/);
  assert.doesNotMatch(hook, /load(AVPlayer|Avbridge|H265web)\(/);
  assert.doesNotMatch(hook, /createPlaybackEngineAdapter\(\{\s*id: ENGINE_ID\./);
  assert.doesNotMatch(
    hook,
    /createNativePlaybackEngine|createMediaElementEngine|createHlsPlaybackEngine|createMpegtsPlaybackEngine/,
  );
  assert.match(hook, /createPlaybackEngineAdapter\(\{ id: engineId, engine, ownsEngine \}\)/);
});
