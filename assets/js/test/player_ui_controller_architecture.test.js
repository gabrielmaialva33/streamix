import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const controllerUrl = new URL("../player/player_ui_controller.js", import.meta.url);
const browserIntegrationUrl = new URL("../player/playback_browser_integration.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("browser integration routes owned fullscreen presentation through PlayerUiController", async () => {
  const hook = await source(hookUrl);
  const browserIntegration = await source(browserIntegrationUrl);

  assert.match(hook, /createPlayerUiController\s*\(\s*\{/);
  assert.match(hook, /playerUIController\??\.updateSpeedUI\s*\(/);
  assert.doesNotMatch(hook, /playerUIController\??\.updateFullscreenUI\s*\(/);
  assert.match(browserIntegration, /presentation\.updateFullscreenUI\s*\(/);

  assert.equal(hook.includes("this.playerUI.updateSpeedUI("), false);
  assert.equal(hook.includes("this.playerUI?.updateSpeedUI("), false);
  assert.equal(hook.includes("this.playerUI.updateFullscreenUI("), false);
  assert.equal(hook.includes("this.playerUI?.updateFullscreenUI("), false);
});

test("PlayerUiController owns the speed and fullscreen presentation contract", async () => {
  const controller = await source(controllerUrl);

  for (const method of ["updateSpeedUI", "updateFullscreenUI"]) {
    assert.match(controller, new RegExp(`"${method}"`));
    assert.match(controller, new RegExp(`\\n  ${method}\\([^)]*\\) \\{`));
    assert.match(controller, new RegExp(`this\\.ui\\.${method}\\(`));
  }

  assert.match(
    controller,
    /updateFullscreenUI\(active\)[\s\S]*?this\.ui\.updateFullscreenUI\(Boolean\(active\)\)/,
  );
});
