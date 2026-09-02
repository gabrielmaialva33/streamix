import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function source(relativePath) {
  return readFile(new URL(relativePath, import.meta.url), "utf8");
}

test("the coordinator owns HLS retry state without depending on the Phoenix hook", async () => {
  const coordinator = await source("../player/hls_recovery_coordinator.js");

  assert.match(coordinator, /runGuardedPlaybackRetry/);
  assert.match(coordinator, /scheduleGuardedPlaybackRetry/);
  assert.match(coordinator, /class HlsRecoveryCoordinator/);
  assert.doesNotMatch(coordinator, /hooks\/video_player|Phoenix|LiveSocket|pushEvent/);
  assert.doesNotMatch(coordinator, /playWithMpegts|playNative|AVPlayer|ENGINE_ID\.MPEGTS/);
});

test("the VideoPlayer composes the recovery policy while delegating HLS recovery", async () => {
  const hook = await source("../hooks/video_player.js");

  assert.match(hook, /createHlsRecoveryCoordinator\([\s\S]*onFailure:[\s\S]*onRecovering:/);
  assert.match(
    hook,
    /import \{ createEngineRecoveryPolicy \} from "\.\.\/player\/engine_recovery_policy\.js";/,
  );
  assert.match(
    hook,
    /this\.engineRecoveryPolicy = createEngineRecoveryPolicy\(\{\s*dependencies: \{ createErrorReport, detectErrorPatterns, formatErrorForLog \},\s*host: this\.buildEngineRecoveryHost\(\),/,
  );
  assert.match(
    hook,
    /onFailure: \(error\) => this\.engineRecoveryPolicy\?\.reportHlsRecoveryFailure\(error\)/,
  );
  assert.match(
    hook,
    /handleStreamError\(type, data\) \{\s*return this\.engineRecoveryPolicy\?\.handleStreamError\(type, data\);/,
  );
  assert.match(
    hook,
    /recoverFromMpegtsError\(data\) \{\s*return this\.engineRecoveryPolicy\?\.recoverFromMpegtsError\(data\) \?\? Promise\.resolve\(false\);/,
  );
  assert.doesNotMatch(hook, /_hlsRecoveryAttempts|_hlsRetryTimer/);
  assert.doesNotMatch(hook, /runGuardedPlaybackRetry|scheduleGuardedPlaybackRetry/);
  assert.doesNotMatch(
    hook,
    /handleHlsStreamError\(|handleHlsFallback\(|logHlsRecoveryDecision\(|reportHlsRecoveryFailure\(error\) \{/,
  );
  assert.doesNotMatch(hook, /HLS_RECOVERY_OUTCOME|HLS_RECOVERY_REASON|HLS_RECOVERY_OPERATION/);
  assert.doesNotMatch(hook, /hlsRecoveryCoordinator\.handle\(/);
});

test("EngineRecoveryPolicy owns cross-engine fallback behind an explicit host", async () => {
  const policy = await source("../player/engine_recovery_policy.js");

  assert.match(policy, /ENGINE_RECOVERY_HOST_METHODS = Object\.freeze\(\[/);
  assert.match(
    policy,
    /assertActivationHost\(host, ENGINE_RECOVERY_HOST_METHODS, "EngineRecoveryPolicy"\)/,
  );
  assert.match(
    policy,
    /handleHlsStreamError\(data\)[\s\S]*getHlsRecoveryCoordinator\(\)[\s\S]*\.handle\(data, this\.host\.getHlsRecoveryContext\(\)\)/,
  );
  assert.match(
    policy,
    /handleHlsFallback\(decision\)[\s\S]*this\.host\.playWithMpegts\(\)[\s\S]*this\.host\.playNative\(\)/,
  );
  assert.match(policy, /this\.host\.getMpegtsRecoveryCoordinator\(\)\.handle\(data, \{/);
  assert.match(policy, /this\.host\.pushEvent\("player_error", \{/);
  assert.match(policy, /this\.host\.pushEvent\("request_token_refresh", \{\}\)/);
  assert.doesNotMatch(policy, /hooks\/video_player|LiveSocket|Phoenix|pushEventSafe/);
  assert.doesNotMatch(policy, /window\.|document\.|globalThis\.|error_telemetry/);
  assert.doesNotMatch(policy, /runGuardedPlaybackRetry|scheduleGuardedPlaybackRetry|new Hls\(/);
});

test("transport-local HLS recovery operations remain exposed by StreamLoader", async () => {
  const streamLoader = await source("../media/stream_loader.js");
  const coordinator = await source("../player/hls_recovery_coordinator.js");

  for (const method of ["loadHlsSoft", "startLoad", "recoverMediaError"]) {
    assert.match(streamLoader, new RegExp(`${method}\\(`));
    assert.match(coordinator, new RegExp(`"${method}"`));
  }

  assert.doesNotMatch(coordinator, /new Hls\(|import\("hls\.js"\)/);
});
