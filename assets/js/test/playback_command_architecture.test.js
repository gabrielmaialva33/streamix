import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const hookSource = readFileSync(new URL("../hooks/video_player.js", import.meta.url), "utf8");
const controllerSource = readFileSync(
  new URL("../player/playback_command_controller.js", import.meta.url),
  "utf8",
);

function compact(source) {
  return source.replace(/\s+/g, " ").trim();
}

test("VideoPlayer composes one transport-command controller", () => {
  const normalized = compact(hookSource);

  assert.match(
    hookSource,
    /import \{ createPlaybackCommandController \} from "\.\.\/player\/playback_command_controller";/,
  );
  assert.ok(
    normalized.includes(
      "this.initUI(); this.initPlaybackCommandController(); this.updateVolumeUI();",
    ),
  );
  assert.match(
    hookSource,
    /initPlaybackCommandController\(\) \{[\s\S]*createPlaybackCommandController\(\{/,
  );
  assert.match(
    hookSource,
    /this\.playbackCommandController\?\.destroy\(\);\s*this\.playbackCommandController = null;/,
  );
});

test("transport commands remain thin compatibility delegates on the hook", () => {
  const normalized = compact(hookSource);
  const expectedDelegates = [
    "async togglePlayPause(options = {}) { return this.playbackCommandController?.togglePlayPause(options); }",
    "toggleMute() { return this.playbackCommandController?.toggleMute(); }",
    "adjustVolume(delta) { return this.playbackCommandController?.adjustVolume(delta); }",
    "seek(seconds, options = {}) { return this.playbackCommandController?.seek(seconds, options); }",
    "seekTo(time, options = {}) { return this.playbackCommandController?.seekTo(time, options); }",
    "seekNativeTo(time) { return this.playbackCommandController?.seekNativeTo(time) ?? false; }",
    "seekLiveTo(time) { return this.playbackCommandController?.seekLiveTo(time) ?? false; }",
    "setPlaybackRate(rate, options = {}) { return this.playbackCommandController?.setPlaybackRate(rate, options) ?? false; }",
    "getCurrentTime() { return this.playbackCommandController?.getCurrentTime() ?? 0; }",
    "getDuration() { return this.playbackCommandController?.getDuration() ?? 0; }",
    "getPlaybackRate() { return this.playbackCommandController?.getPlaybackRate() ?? 1; }",
    "isPaused() { return this.playbackCommandController?.isPaused() ?? true; }",
  ];

  for (const delegate of expectedDelegates) {
    assert.ok(normalized.includes(delegate), `missing thin delegate: ${delegate}`);
  }

  const start = hookSource.indexOf("  async togglePlayPause(options = {})");
  const end = hookSource.indexOf("  trackWatchTime()", start);
  assert.ok(start >= 0 && end > start);

  const commandRegion = hookSource.slice(start, end);
  for (const implementationDetail of [
    "relativeSeekTarget",
    "clampSeekTime",
    "savePlaybackRate",
    "canPlayType",
    ".seekable",
    "markIntentionalPause",
    "getManagedPlaybackEngine",
  ]) {
    assert.equal(
      commandRegion.includes(implementationDetail),
      false,
      `hook transport region still owns ${implementationDetail}`,
    );
  }
});

test("the controller owns transport policy but not engine lifecycle", () => {
  for (const policy of [
    "relativeSeekTarget",
    "clampSeekTime",
    "savePlaybackRate",
    "NATIVE_HLS_MIME_TYPE",
    "rejectViewerTransportControl",
    "getManagedPlaybackEngine",
    "getNativePlaybackEngine",
  ]) {
    assert.ok(controllerSource.includes(policy), `controller is missing ${policy}`);
  }

  for (const forbiddenResponsibility of [
    "createAVPlayer",
    "createHls",
    "createMpegts",
    "PlaybackEngineTransitionController",
    "SourceFailoverController",
  ]) {
    assert.equal(
      controllerSource.includes(forbiddenResponsibility),
      false,
      `command controller must not own ${forbiddenResponsibility}`,
    );
  }
});
