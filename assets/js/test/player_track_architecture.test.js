import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const controllerUrl = new URL("../player/player_track_controller.js", import.meta.url);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("PlayerTrackController remains independent of engines, Phoenix, and the hook", async () => {
  const controller = await source(controllerUrl);

  assert.doesNotMatch(controller, /phoenix|liveview|video_player/i);
  assert.doesNotMatch(controller, /hls|mpegts|avplayer|avbridge|h265web|native_playback/i);
  assert.doesNotMatch(controller, /document\.|window\.|querySelector/);
});

test("VideoPlayer creates one track controller with narrow legacy boundaries", async () => {
  const hook = await source(hookUrl);

  assert.match(
    hook,
    /import \{ createPlayerTrackController \} from "\.\.\/player\/player_track_controller\.js";/,
  );
  assert.match(hook, /this\.playerTrackController = createPlayerTrackController\(\{/);
  assert.match(hook, /refreshAudioTracks: \(\) => this\.refreshAudioTracksLegacy\(\)/);
  assert.match(hook, /refreshSubtitleTracks: \(\) => this\.refreshSubtitleTracksLegacy\(\)/);
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
