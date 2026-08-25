import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const controllerUrl = new URL("../player/player_ui_controller.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("PlayerUiController remains independent of Phoenix and the VideoPlayer hook", async () => {
  const controller = await source(controllerUrl);

  assert.doesNotMatch(controller, /phoenix|liveview|video_player|pushEvent/i);
  assert.match(controller, /export class PlayerUiController/);
  assert.match(controller, /export function createPlayerUiController/);
});

test("VideoPlayer delegates presentation coordination to PlayerUiController", async () => {
  const hook = await source(hookUrl);

  assert.match(hook, /createPlayerUiController/);
  assert.match(hook, /playerUIController = createPlayerUiController\(/);
  assert.match(hook, /playerUI: this\.playerUIController/);
  assert.match(hook, /return this\.playerUIController\?\.updateTime\(\) \?\? null/);
  assert.match(hook, /return this\.playerUIController\?\.updateBuffer\(\) \?\? null/);
  assert.match(hook, /this\.playerUIController\?\.disablePiP\(\)/);
  assert.match(hook, /this\.playerUIController\?\.destroy\(\)/);
});

test("VideoPlayer does not bypass the presentation controller for coordinated UI state", async () => {
  const hook = await source(hookUrl);
  const bypassedMethods = [
    "clearHideControlsTimeout",
    "destroy",
    "hideError",
    "hideLoading",
    "scheduleHideControls",
    "setNativeControlsMode",
    "setPiPAvailable",
    "showControls",
    "showError",
    "showLoading",
    "updateBufferBar",
    "updatePiPUI",
    "updatePlayPauseUI",
    "updateTimeUI",
  ];

  for (const method of bypassedMethods) {
    assert.doesNotMatch(
      hook,
      new RegExp(`this\\.playerUI(?:\\?\\.|\\.)${method}\\(`),
      `VideoPlayer must route ${method}() through PlayerUiController`,
    );
  }
});

test("PlayerUiController owns bounded presentation responsibilities only", async () => {
  const controller = await source(controllerUrl);

  for (const forbidden of [
    "Hls",
    "mpegts",
    "AVPlayer",
    "StreamLoader",
    "sourceFailover",
    "fetch(",
  ]) {
    assert.equal(controller.includes(forbidden), false, `${forbidden} leaked into UI coordination`);
  }
});
