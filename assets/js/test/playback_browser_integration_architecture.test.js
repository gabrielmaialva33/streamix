import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const hookSource = readFileSync(new URL("../hooks/video_player.js", import.meta.url), "utf8");
const integrationSource = readFileSync(
  new URL("../player/playback_browser_integration.js", import.meta.url),
  "utf8",
);

function compact(source) {
  return source.replace(/\s+/g, " ").trim();
}

test("VideoPlayer composes browser integration and keeps compatibility delegates thin", () => {
  const hook = compact(hookSource);

  assert.match(
    hookSource,
    /import \{ createPlaybackBrowserIntegration \} from "\.\.\/player\/playback_browser_integration\.js";/,
  );
  assert.ok(
    hook.includes(
      "this.initUI(); this.initPlaybackCommandController(); this.initPlaybackBrowserIntegration();",
    ),
  );

  for (const delegate of [
    "setupKeyboardShortcuts() { return this.playbackBrowserIntegration?.setupKeyboardShortcuts() ?? false; }",
    "toggleFullscreen() { return this.playbackBrowserIntegration?.toggleFullscreen(); }",
    "async togglePiP() { return this.playbackBrowserIntegration?.togglePiP(); }",
    "isPiPSupported() { return this.playbackBrowserIntegration?.isPiPSupported() ?? false; }",
    "setPiPState(active) { return this.playbackBrowserIntegration?.setPiPState(active) ?? false; }",
    "syncPiPAvailability() { return this.playbackBrowserIntegration?.syncPiPAvailability() ?? false; }",
    "disablePiPForCanvasPlayback() { return this.playbackBrowserIntegration?.disablePiPForCanvasPlayback(); }",
    "setupPlaybackSystemIntegration() { return this.playbackBrowserIntegration?.setupPlaybackSystemIntegration() ?? false; }",
    "setPlaybackSystemState(state) { return this.playbackBrowserIntegration?.setPlaybackSystemState(state) ?? false; }",
    "updateMediaSessionPosition(options = {}) { return this.playbackBrowserIntegration?.updateMediaSessionPosition(options) ?? false; }",
  ]) {
    assert.ok(hook.includes(delegate), `missing thin browser integration delegate: ${delegate}`);
  }
});

test("browser API ownership does not leak back into VideoPlayer", () => {
  for (const leakedOwnership of [
    "KeyboardManager",
    "createMediaSessionController",
    "createScreenWakeLockController",
    "exitPictureInPicture",
    "isPictureInPictureSupported",
    "togglePictureInPicture",
    '"fullscreenchange"',
    '"webkitfullscreenchange"',
    '"enterpictureinpicture"',
    '"leavepictureinpicture"',
    '"webkitpresentationmodechanged"',
    "requestFullscreen",
    "webkitEnterFullscreen",
    "webkitExitFullscreen",
  ]) {
    assert.equal(
      hookSource.includes(leakedOwnership),
      false,
      `${leakedOwnership} must remain owned by PlaybackBrowserIntegration`,
    );
  }
});

test("browser integration consumes commands without owning playback engines", () => {
  for (const ownedBrowserConcern of [
    "KeyboardManager",
    "createMediaSessionController",
    "createScreenWakeLockController",
    "togglePictureInPicture",
    '"fullscreenchange"',
    '"webkitfullscreenchange"',
    '"enterpictureinpicture"',
    '"leavepictureinpicture"',
    '"webkitpresentationmodechanged"',
  ]) {
    assert.ok(integrationSource.includes(ownedBrowserConcern));
  }

  for (const command of [
    "commands.togglePlayPause",
    "commands.toggleMute",
    "commands.adjustVolume",
    "commands.seek",
    "commands.seekTo",
    "commands.setPlaybackRate",
  ]) {
    assert.ok(integrationSource.includes(command), `browser integration must consume ${command}`);
  }

  for (const forbiddenResponsibility of [
    "hls.js",
    "mpegts.js",
    "AVPlayer",
    "H265Web",
    "engine_selector",
    "engine_factory",
    "source_failover",
    "recovery_coordinator",
    "StreamLoader",
  ]) {
    assert.equal(
      integrationSource.includes(forbiddenResponsibility),
      false,
      `browser integration must not own ${forbiddenResponsibility}`,
    );
  }
});
