import assert from "node:assert/strict";
import test from "node:test";
import { createMobileControls } from "../player/mobile_controls.js";

class FakeElement extends EventTarget {
  closest() {
    return null;
  }
}

test("routes touch taps and removes every listener on destroy", () => {
  const root = new FakeElement();
  const controls = new FakeElement();
  const video = new FakeElement();
  const calls = [];
  const timestamps = [1_000, 1_200];

  const controller = createMobileControls({
    root,
    controls,
    video,
    presentation: {
      cancelControlsAutoHide: () => calls.push("cancel-auto-hide"),
      keepControlsVisible: () => calls.push("keep-visible"),
      revealControls: () => calls.push("reveal"),
      scheduleControlsAutoHide: () => calls.push("schedule-auto-hide"),
      toggleControlsVisibility: () => calls.push("toggle-controls"),
    },
    shouldUseNativeControls: () => false,
    toggleFullscreen: () => calls.push("fullscreen"),
    environment: {
      window: { ontouchstart: null },
      navigator: { maxTouchPoints: 1 },
      Element: FakeElement,
    },
    now: () => timestamps.shift(),
  });

  root.dispatchEvent(new Event("click", { cancelable: true }));
  root.dispatchEvent(new Event("click", { cancelable: true }));
  video.dispatchEvent(new Event("pause"));

  assert.deepEqual(calls, ["reveal", "toggle-controls", "fullscreen", "keep-visible"]);

  controller.destroy();
  root.dispatchEvent(new Event("click"));
  video.dispatchEvent(new Event("play"));

  assert.equal(calls.length, 4);
});
