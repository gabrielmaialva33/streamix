import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const controllerUrl = new URL(
  "../player/playback_engine_transition_controller.js",
  import.meta.url,
);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const avPlayerActivationUrl = new URL("../player/avplayer_engine_activation.js", import.meta.url);
const mpegtsActivationUrl = new URL("../player/mpegts_engine_activation.js", import.meta.url);
const playerStateUrl = new URL("../player/player_state.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

function methodIndex(hook, methodName, fromIndex = 0) {
  const synchronous = hook.indexOf(`  ${methodName}(`, fromIndex);
  const asynchronous = hook.indexOf(`  async ${methodName}(`, fromIndex);
  const indexes = [synchronous, asynchronous].filter((index) => index >= 0);
  return indexes.length > 0 ? Math.min(...indexes) : -1;
}

function methodSlice(hook, methodName, nextMethodName) {
  const start = methodIndex(hook, methodName);
  const end = methodIndex(hook, nextMethodName, start + 1);
  assert.notEqual(start, -1, `missing ${methodName}()`);
  assert.notEqual(end, -1, `missing boundary after ${methodName}()`);
  return hook.slice(start, end);
}

test("transition ordering stays independent from concrete engines, DOM, and Phoenix", async () => {
  const controller = await source(controllerUrl);

  assert.match(controller, /export class PlaybackEngineTransitionController/);
  assert.match(controller, /PLAYBACK_ENGINE_TRANSITION_PHASE/);
  assert.match(controller, /async _cleanupEngine\(context\)/);
  assert.match(controller, /await this\._cleanupEngine\(context\);\s*try \{/);
  assert.doesNotMatch(
    controller,
    /AVPlayerWrapper|HlsPlaybackEngine|MpegtsPlaybackEngine|hooks\/video_player/,
  );
  assert.doesNotMatch(controller, /document\.|window\.|querySelector|Phoenix|LiveSocket/);
});

test("VideoPlayer composes one transition controller with narrow lifecycle boundaries", async () => {
  const [hook, playerState] = await Promise.all([source(hookUrl), source(playerStateUrl)]);

  assert.match(
    hook,
    /import \{ createPlaybackEngineTransitionController \} from "\.\.\/player\/playback_engine_transition_controller\.js";/,
  );
  assert.match(
    hook,
    /this\.playbackEngineTransitionController = createPlaybackEngineTransitionController\(\{/,
  );
  assert.match(hook, /beginSession: \(\) => this\.beginPlaybackSession\(\)/);
  assert.match(
    hook,
    /isSessionCurrent: \(sessionId\) => this\.isCurrentPlaybackSession\(sessionId\)/,
  );
  assert.match(hook, /drainTeardown: \(\) => this\.avPlayerTeardownQueue\.drain\(\)/);
  assert.match(hook, /destroyEngine: \(engine\) => this\.teardownAVPlayer\(engine\)/);
  assert.match(playerState, /playbackEngineTransitionController: null/);
  assert.match(playerState, /_switchingToAVPlayer: false/);
});

test("native-to-AVPlayer transaction owns the complete ordered stage surface", async () => {
  const activation = await source(avPlayerActivationUrl);
  const transition = methodSlice(activation, "transition", "createEngine");

  assert.match(transition, /const controller = this\.host\.getTransitionController\(\)/);
  assert.match(transition, /controller\.transition\(\{/);
  assert.match(transition, /\bcapture,\s*sessionId,\s*prepare:/);
  for (const stage of [
    "prepare",
    "releasePrevious",
    "createEngine",
    "initializeEngine",
    "loadEngine",
    "registerEngine",
    "restoreEngine",
    "activateEngine",
    "complete",
    "rollbackEngine",
    "onFailure",
  ]) {
    assert.match(transition, new RegExp(`${stage}:`), `missing ${stage}`);
  }

  assert.match(transition, /this\.host\.trackManagedEngine\(ENGINE_ID\.AVPLAYER, engine\)/);
  assert.match(transition, /this\.host\.releaseEngine\(ENGINE_ID\.AVPLAYER\)/);
  assert.match(transition, /skipTeardown: true/);
});

test("initial AVPlayer selection reuses the initPlayer session without fallback policy", async () => {
  const [controller, hook, activation] = await Promise.all([
    source(controllerUrl),
    source(hookUrl),
    source(avPlayerActivationUrl),
  ]);
  const initPlayer = methodSlice(hook, "initPlayer", "buildEngineRecoveryHost");
  const startup = methodSlice(activation, "activate", "tryFallback");
  const transaction = methodSlice(activation, "transition", "createEngine");

  assert.match(
    initPlayer,
    /void this\.playbackEngineActivation\.activate\(engine, \{ sessionId \}\);/,
  );
  assert.match(hook, /\[ENGINE_SELECTION\.AVPLAYER\]: this\.avPlayerEngineActivation,/);
  assert.doesNotMatch(initPlayer, /tryAVPlayerFallback\(|startWithAVPlayer\(/);

  assert.match(startup, /key: "startup-avplayer"/);
  assert.match(startup, /sessionId,/);
  assert.match(startup, /initializeEngine: true/);
  assert.match(startup, /recordSuccess: true/);
  assert.match(startup, /this\.host\.markAVPlayerAttempted\(\)/);
  assert.doesNotMatch(
    startup,
    /canAttemptFallback|fallbackAttempts|lastFallbackTime|fallback: true/,
  );

  assert.match(transaction, /sessionId = null/);
  assert.match(transaction, /controller\.transition\(\{[\s\S]*sessionId,/);
  assert.match(
    controller,
    /context\.sessionId = context\.options\.sessionId \?\? this\._beginSession\(\)/,
  );
});

test("fallback and track-switch entrypoints retain policy but delegate transaction mechanics", async () => {
  const [hook, activation] = await Promise.all([source(hookUrl), source(avPlayerActivationUrl)]);
  const fallback = methodSlice(activation, "tryFallback", "switchWithTrack");
  const trackSwitch = methodSlice(activation, "switchWithTrack", "transition");

  assert.match(fallback, /this\.host\.canAttemptFallback\(\)/);
  assert.match(
    fallback,
    /this\.host\.isAVPlayerAttempted\(\) \|\| this\.host\.isUsingAVPlayer\(\)/,
  );
  assert.match(fallback, /this\.host\.recordFallbackAttempt\(\)/);
  assert.match(fallback, /key: "native-to-avplayer-fallback"/);
  assert.match(fallback, /return this\.transition\(\{/);

  assert.match(trackSwitch, /key: `native-to-avplayer-\$\{trackType\}-track`/);
  assert.match(trackSwitch, /initializeEngine: true/);
  assert.match(trackSwitch, /return this\.transition\(\{/);

  for (const entrypoint of [fallback, trackSwitch]) {
    assert.doesNotMatch(entrypoint, /beginPlaybackSession\(/);
    assert.doesNotMatch(entrypoint, /drain\(/);
    assert.doesNotMatch(entrypoint, /new AVPlayerWrapper/);
    assert.doesNotMatch(entrypoint, /trackManagedEngine\(/);
    assert.doesNotMatch(entrypoint, /await avPlayer\.(init|load|seek|play)\(/);
  }

  assert.match(hook, /canAttemptFallback\(\) \{/, "circuit-breaker policy stays on the hook");
  assert.match(
    hook,
    /tryAVPlayerFallback\(\) \{\s*return this\.avPlayerEngineActivation\?\.tryFallback\(\)/,
  );
  assert.doesNotMatch(hook, /this\._switchingToAVPlayer = true/);
});

test("cleanup cancels transitions and terminal teardown destroys the controller first", async () => {
  const hook = await source(hookUrl);
  const cleanup = methodSlice(hook, "cleanup", "resetNativeMediaElement");

  assert.match(cleanup, /this\.playbackSessionId \+= 1;/);
  assert.match(cleanup, /this\.playbackEngineTransitionController\?\.cancel\("cleanup"\)/);
  assert.ok(
    cleanup.indexOf("this.playbackSessionId += 1;") <
      cleanup.indexOf('this.playbackEngineTransitionController?.cancel("cleanup")'),
  );

  assert.match(hook, /this\.playbackEngineTransitionController\?\.destroy\(\);/);
  assert.ok(
    hook.indexOf("this.playbackEngineTransitionController?.destroy();") <
      hook.indexOf("this.cleanup();", hook.indexOf("  destroyed()")),
  );
  assert.match(hook, /this\.playbackEngineTransitionController = null;/);
});

test("AVPlayer-to-native recovery reuses the transition controller without duplicate hook state", async () => {
  const [controller, hook, playerState, activation] = await Promise.all([
    source(controllerUrl),
    source(hookUrl),
    source(playerStateUrl),
    source(avPlayerActivationUrl),
  ]);
  const recovery = methodSlice(activation, "recoverToNative", "handleEngineError");
  const errorHandler = methodSlice(activation, "handleEngineError", "detectTracks");

  assert.match(controller, /recover\(options = \{\}\)/);
  assert.match(controller, /sourceSessionId/);
  assert.match(controller, /async _runRecovery\(context\)/);
  assert.match(controller, /async _releaseRecoverySource\(context, throwOnError\)/);
  assert.match(controller, /await this\._releaseRecoverySource\(context, true\)/);
  assert.match(controller, /context\.sessionId = this\._beginSession\(\)/);

  assert.match(recovery, /controller\.recover\(\{/);
  assert.match(recovery, /key: "avplayer-to-native-recovery"/);
  assert.match(recovery, /sourceSessionId: sessionId/);
  assert.match(recovery, /engine: skipTeardown \? null : avPlayer/);
  assert.match(recovery, /resolvePlaybackResumeTime\(avPlayer, resumeTime\)/);
  assert.match(recovery, /forgetRecommendedPlayer\(contentKey\)/);
  assert.match(recovery, /this\.host\.releaseEngine\(ENGINE_ID\.AVPLAYER\)/);
  assert.match(recovery, /restoreNative: \(\) => this\.restoreNativePresentation\(\)/);
  assert.match(recovery, /this\.host\.initPlayer\(\{ sessionId: nativeSessionId \}\)/);

  assert.match(errorHandler, /key\?\.startsWith\("native-to-avplayer"\)/);
  assert.match(errorHandler, /cancel\("avplayer_error"\)/);
  assert.match(errorHandler, /skipTeardown: true/);

  assert.doesNotMatch(hook, /_avPlayerFailureSessionId|_avPlayerFailurePromise/);
  assert.doesNotMatch(hook, /revertToNativePlayer\(/);
  assert.doesNotMatch(playerState, /_avPlayerFailureSessionId|_avPlayerFailurePromise/);
});

test("native restart consumes the recovery session instead of creating a second one", async () => {
  const hook = await source(hookUrl);
  const initPlayer = methodSlice(hook, "initPlayer", "playNative");

  assert.match(initPlayer, /initPlayer\(\{ sessionId: providedSessionId = null \} = \{\}\)/);

  // A supplied session is reused; only the unsupplied case begins a new one.
  assert.match(
    initPlayer,
    /if \(providedSessionId == null\) \{\s*sessionId = this\.beginPlaybackSession\(\);/,
  );
  assert.doesNotMatch(initPlayer, /providedSessionId \?\? this\.beginPlaybackSession\(\)/);

  // cleanup() advances playbackSessionId to invalidate in-flight work, so a
  // supplied session has to be re-adopted after it. Without this every
  // isSessionCurrent() check downstream compares against the bumped id, the
  // activation aborts as stale, and the AVPlayer-to-native fallback restores
  // no engine at all.
  const afterCleanup = initPlayer.slice(initPlayer.indexOf("this.cleanup();"));
  assert.match(afterCleanup, /this\.playbackSessionId = providedSessionId;/);
});

test("transition contexts can override provisional and recovery engine destruction", async () => {
  const controller = await source(controllerUrl);
  const overridePattern =
    /typeof context\.options\.destroyEngine === "function"[\s\S]*?context\.options\.destroyEngine[\s\S]*?: this\._destroyEngine/g;

  assert.equal(controller.match(overridePattern)?.length, 2);
});

test("initial MPEG-TS activation uses the shared transition controller with a local destroyer", async () => {
  const [hook, activation] = await Promise.all([source(hookUrl), source(mpegtsActivationUrl)]);
  const transition = methodSlice(activation, "activate", "load");
  const loader = activation.slice(activation.indexOf("  async load("));

  assert.match(hook, /getTransitionController: \(\) => this\.playbackEngineTransitionController/);
  assert.doesNotMatch(hook, /loadMpegtsForTransition|startup-mpegts/);

  assert.match(transition, /const controller = this\.host\.getTransitionController\(\)/);
  assert.match(transition, /controller\.transition\(\{/);
  assert.match(transition, /key: `startup-mpegts-\$\{type\}`/);
  assert.match(transition, /sessionId: request\.sessionId,/);
  assert.match(transition, /createEngine: \(\) => this\.host\.ensureStreamLoader\(\)/);
  assert.match(transition, /loadEngine: \(context\) => this\.load\(type, context\.sessionId\)/);
  assert.match(transition, /loader\.getMpegtsEngine\(\)/);
  assert.match(transition, /destroyEngine: async \(loader\) =>/);
  assert.match(transition, /await loader\.destroy\(\)/);
  assert.match(transition, /this\.host\.clearStreamLoader\(loader\)/);
  assert.match(transition, /this\.host\.releaseEngine\(ENGINE_ID\.MPEGTS\)/);
  assert.match(transition, /context\.capture\?\.type === "flv"/);
  assert.match(transition, /errorType: "OtherError"/);
  assert.doesNotMatch(transition, /guardPlaybackLoad/);
  assert.doesNotMatch(transition, /teardownAVPlayer/);

  assert.match(loader, /await this\.deps\.guardPlaybackLoad\(\{/);
  assert.match(loader, /destroy: \(\) => undefined/);
  assert.match(loader, /this\.host\.registerMediaElementEngine\(ENGINE_ID\.MPEGTS, mpegtsEngine\)/);
  assert.match(loader, /throw result\.error/);
  assert.doesNotMatch(loader, /recoverFromMpegtsError/);
  assert.doesNotMatch(loader, /teardownStreamLoaderForTransition/);
});
