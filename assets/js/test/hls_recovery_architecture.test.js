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

test("the VideoPlayer keeps cross-engine fallback while delegating HLS recovery", async () => {
  const hook = await source("../hooks/video_player.js");

  assert.match(hook, /createHlsRecoveryCoordinator\([\s\S]*onFailure:[\s\S]*onRecovering:/);
  assert.match(hook, /handleHlsStreamError\(data\)[\s\S]*hlsRecoveryCoordinator\.handle/);
  assert.match(hook, /handleHlsFallback\(decision\)[\s\S]*playWithMpegts\(\)[\s\S]*playNative\(\)/);
  assert.doesNotMatch(hook, /_hlsRecoveryAttempts|_hlsRetryTimer/);
  assert.doesNotMatch(hook, /runGuardedPlaybackRetry|scheduleGuardedPlaybackRetry/);
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
