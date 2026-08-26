import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const controllerUrl = new URL(
  "../player/playback_engine_transition_controller.js",
  import.meta.url,
);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
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
  const hook = await source(hookUrl);
  const transition = methodSlice(hook, "transitionNativeToAVPlayer", "tryAVPlayerFallback");

  assert.match(transition, /this\.playbackEngineTransitionController\.transition\(\{/);
  assert.match(transition, /\bcapture,\s*prepare:/);
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

  assert.match(transition, /this\.trackManagedEngine\(ENGINE_ID\.AVPLAYER, engine\)/);
  assert.match(transition, /this\.playbackOrchestrator\?\.releaseEngine\(ENGINE_ID\.AVPLAYER\)/);
  assert.match(transition, /skipTeardown: true/);
});

test("fallback and track-switch entrypoints retain policy but delegate transaction mechanics", async () => {
  const hook = await source(hookUrl);
  const fallback = methodSlice(hook, "tryAVPlayerFallback", "detectAVPlayerTracks");
  const trackSwitch = methodSlice(
    hook,
    "switchToAVPlayerWithTrack",
    "restoreNativePlayerPresentation",
  );

  assert.match(fallback, /this\.canAttemptFallback\(\)/);
  assert.match(fallback, /this\.avPlayerAttempted \|\| this\.usingAVPlayer/);
  assert.match(fallback, /key: "native-to-avplayer-fallback"/);
  assert.match(fallback, /return this\.transitionNativeToAVPlayer\(\{/);

  assert.match(trackSwitch, /key: `native-to-avplayer-\$\{trackType\}-track`/);
  assert.match(trackSwitch, /initializeEngine: true/);
  assert.match(trackSwitch, /return this\.transitionNativeToAVPlayer\(\{/);

  for (const entrypoint of [fallback, trackSwitch]) {
    assert.doesNotMatch(entrypoint, /beginPlaybackSession\(/);
    assert.doesNotMatch(entrypoint, /avPlayerTeardownQueue\.drain\(/);
    assert.doesNotMatch(entrypoint, /new AVPlayerWrapper/);
    assert.doesNotMatch(entrypoint, /trackManagedEngine\(/);
    assert.doesNotMatch(entrypoint, /await avPlayer\.(init|load|seek|play)\(/);
  }

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
