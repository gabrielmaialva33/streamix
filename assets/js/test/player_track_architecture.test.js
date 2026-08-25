import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const controllerUrl = new URL("../player/player_track_controller.js", import.meta.url);
const hlsEngineUrl = new URL("../player/hls_playback_engine.js", import.meta.url);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const streamLoaderUrl = new URL("../media/stream_loader.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("PlayerTrackController remains independent of engines, Phoenix, and the hook", async () => {
  const controller = await source(controllerUrl);

  assert.doesNotMatch(controller, /phoenix|liveview|video_player/i);
  assert.doesNotMatch(controller, /hls|mpegts|avplayer|avbridge|h265web|native_playback/i);
  assert.doesNotMatch(controller, /document\.|window\.|querySelector/);
});

test("HLS track state stays behind the playback engine contract", async () => {
  const [hlsEngine, hook, streamLoader] = await Promise.all([
    source(hlsEngineUrl),
    source(hookUrl),
    source(streamLoaderUrl),
  ]);

  assert.doesNotMatch(hook, /\bhls\.(audioTracks|audioTrack|subtitleTracks|subtitleTrack)\b/);
  assert.doesNotMatch(
    streamLoader,
    /this\.hls\.(audioTracks|audioTrack|subtitleTracks|subtitleTrack)\b/,
  );
  assert.match(hlsEngine, /getAudioTracks\(\)/);
  assert.match(hlsEngine, /getSubtitleTracks\(\)/);
  assert.match(hlsEngine, /selectAudioTrack\(trackIndex\)/);
  assert.match(hlsEngine, /selectSubtitleTrack\(trackIndex\)/);
  assert.match(streamLoader, /this\.hlsEngine\?\.selectAudioTrack\?\.\(trackIndex\)/);
  assert.match(streamLoader, /this\.hlsEngine\?\.selectSubtitleTrack\?\.\(trackIndex\)/);
  assert.match(hook, /this\.playbackOrchestrator\.selectAudioTrack\(trackIndex\)/);
  assert.match(hook, /this\.playbackOrchestrator\.selectSubtitleTrack\(trackIndex\)/);
  assert.match(hook, /this\.playbackOrchestrator\?\.trackSnapshot\(\)/);
});

test("VideoPlayer creates one track controller with narrow composition boundaries", async () => {
  const hook = await source(hookUrl);

  assert.match(
    hook,
    /import \{ createPlayerTrackController \} from "\.\.\/player\/player_track_controller\.js";/,
  );
  assert.match(hook, /this\.playerTrackController = createPlayerTrackController\(\{/);
  assert.match(hook, /refreshAudioTracks: \(\) => this\.refreshAudioTracksFromActiveEngine\(\)/);
  assert.match(
    hook,
    /refreshSubtitleTracks: \(\) => this\.refreshSubtitleTracksFromActiveEngine\(\)/,
  );
  assert.match(
    hook,
    /selectAudioTrack: \(trackIndex\) => this\.applyAudioTrackSelection\(trackIndex\)/,
  );
  assert.match(
    hook,
    /selectSubtitleTrack: \(trackIndex\) =>\s*this\.applySubtitleTrackSelection\(trackIndex\)/,
  );
  assert.match(
    hook,
    /setSubtitleOffset: \(offsetMs\) => this\.applySubtitleOffsetSelection\(offsetMs\)/,
  );
  assert.match(
    hook,
    /loadExternalSubtitle: \(\.\.\.args\) =>\s*this\.loadExternalSubtitleForAvPlayerLegacy\(\.\.\.args\)/,
  );
  assert.match(
    hook,
    /loadNativeExternalSubtitle: \(\.\.\.args\) =>\s*this\.loadNativeExternalSubtitleForSessionLegacy\(\.\.\.args\)/,
  );
  assert.match(
    hook,
    /reloadNativeExternalSubtitle: \(\.\.\.args\) =>\s*this\.reloadNativeExternalSubtitleLegacy\(\.\.\.args\)/,
  );
});

test("public track commands delegate through PlayerTrackController", async () => {
  const hook = await source(hookUrl);

  assert.match(
    hook,
    /setAudioTrack\(trackIndex\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.selectAudioTrack\(trackIndex\);/,
  );
  assert.match(
    hook,
    /updateAudioTracks\(\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.refreshAudioTracks\(\);/,
  );
  assert.match(
    hook,
    /setSubtitleTrack\(trackIndex\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.selectSubtitleTrack\(trackIndex\);/,
  );
  assert.match(
    hook,
    /async setSubtitleOffset\(offsetMs\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.setSubtitleOffset\(offsetMs\);/,
  );
  assert.match(
    hook,
    /updateSubtitleTracks\(\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.refreshSubtitleTracks\(\);/,
  );
  assert.match(
    hook,
    /async loadExternalSubtitleIfAvailable\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.loadExternalSubtitle\(\.\.\.args\);/,
  );
  assert.match(
    hook,
    /async loadNativeExternalSubtitleIfAvailable\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.loadNativeExternalSubtitle\(\.\.\.args\);/,
  );
  assert.match(
    hook,
    /async reloadNativeExternalSubtitle\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.reloadNativeExternalSubtitle\(\.\.\.args\);/,
  );
});

test("track controller lifecycle is tied to the player lifecycle", async () => {
  const hook = await source(hookUrl);

  assert.match(hook, /this\.playerTrackController\?\.destroy\(\);/);
  assert.ok(
    hook.indexOf("this.playerTrackController?.destroy();") <
      hook.indexOf("this.playerUIController?.destroy();"),
  );
});
