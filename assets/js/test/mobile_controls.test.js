import assert from "node:assert/strict";
import test from "node:test";
import { createMobileControls } from "../player/mobile_controls.js";
import { clock, fire, PlayerElement } from "./player_controls_helpers.js";

function harness({ touch = true } = {}) {
  const root = new PlayerElement();
  const controls = root.appendChild(new PlayerElement());
  const video = root.appendChild(new PlayerElement("VIDEO"));
  const calls = [];
  const timer = clock();
  const state = { native: false, live: false, visible: true };
  const controller = createMobileControls({
    root,
    controls,
    video,
    presentation: {
      get controlsVisible() {
        return state.visible;
      },
      cancelControlsAutoHide: () => calls.push("cancel"),
      keepControlsVisible: () => calls.push("keep"),
      revealControls: () => calls.push("reveal"),
      scheduleControlsAutoHide: () => calls.push("schedule"),
      toggleControlsVisibility: () => calls.push("controls"),
    },
    shouldUseNativeControls: () => state.native,
    getContentType: () => (state.live ? "live" : "vod"),
    seek: (delta) => calls.push(delta),
    togglePlayPause: () => calls.push("play"),
    toggleFullscreen: () => calls.push("fullscreen"),
    environment: {
      window: touch ? { ontouchstart: null } : {},
      navigator: { maxTouchPoints: touch ? 1 : 0 },
      Element: PlayerElement,
    },
    now: timer.now,
    scheduler: timer,
  });
  calls.length = 0;
  const tap = (clientX) => fire(root, "click", { clientX });
  return { root, controls, video, calls, timer, state, controller, tap };
}

test("single tap toggles controls, side double taps seek and chain for 700ms without fullscreen", () => {
  const { tap, timer, calls, controller } = harness();
  tap(200);
  timer.tick(301);
  assert.deepEqual(calls, ["controls"]);
  calls.length = 0;
  timer.tick(1000);
  tap(200);
  timer.tick(200);
  tap(300);
  timer.tick(650);
  tap(250);
  assert.deepEqual(calls, [-10, -10]);
  timer.tick(701);
  tap(900);
  timer.tick(100);
  tap(950);
  assert.deepEqual(calls, [-10, -10, 10]);
  controller.destroy();
  timer.tick(1000);
  assert.equal(timer.pending, 0);
});

test("a tap on hidden controls shows them at once and a second tap still seeks", () => {
  const { tap, timer, calls, state, controller } = harness();
  state.visible = false;
  tap(200);
  assert.deepEqual(calls, ["reveal"]);
  state.visible = true;
  timer.tick(150);
  tap(200);
  timer.tick(1000);
  assert.deepEqual(calls, ["reveal", -10]);
  controller.destroy();
});

test("centre double tap toggles play once, no single-tap control flicker", () => {
  const { tap, timer, calls, controller } = harness();
  tap(550);
  timer.tick(200);
  tap(550);
  timer.tick(500);
  assert.deepEqual(calls, ["play"]);
  controller.destroy();
});

test("native controls, interactive targets and locked screens ignore gestures", () => {
  const { tap, root, timer, calls, state, controller } = harness();
  state.native = true;
  tap(200);
  timer.tick(100);
  tap(200);
  timer.tick(1000);
  state.native = false;
  root.dataset.playerLocked = "true";
  tap(200);
  timer.tick(100);
  tap(200);
  delete root.dataset.playerLocked;
  const button = root.appendChild(new PlayerElement("BUTTON"));
  fire(root, "click", { target: button, clientX: 900 });
  timer.tick(1000);
  assert.deepEqual(calls, []);
  controller.destroy();
});

test("live disables side seeks and viewers disable play/seek but can reveal controls", () => {
  const { tap, root, timer, calls, state, controller } = harness();
  state.live = true;
  tap(200);
  timer.tick(100);
  tap(200);
  timer.tick(1000);
  root.dataset.partyRole = "viewer";
  tap(550);
  timer.tick(100);
  tap(550);
  timer.tick(1000);
  tap(950);
  timer.tick(100);
  tap(950);
  timer.tick(1000);
  tap(550);
  timer.tick(301);
  assert.deepEqual(calls, ["controls"]);
  controller.destroy();
});

test("two-finger pinch changes fit, suppresses synthetic clicks and obeys lock", () => {
  const { root, timer, tap, calls, controller } = harness();
  const touches = (distance) => [
    { clientX: 0, clientY: 0 },
    { clientX: distance, clientY: 0 },
  ];
  fire(root, "touchstart", { touches: touches(100) });
  const move = fire(root, "touchmove", { touches: touches(140) });
  assert.equal(move.defaultPrevented, true);
  assert.equal(root.dataset.playerFit, "fill");
  fire(root, "touchend", { touches: [] });
  tap(500);
  timer.tick(301);
  assert.equal(calls.includes("play"), false);
  assert.equal(calls.includes("controls"), false);
  fire(root, "touchstart", { touches: touches(100) });
  fire(root, "touchmove", { touches: touches(70) });
  assert.equal(root.dataset.playerFit, undefined);
  root.dataset.playerLocked = "true";
  fire(root, "touchstart", { touches: touches(100) });
  fire(root, "touchmove", { touches: touches(150) });
  assert.equal(root.dataset.playerFit, undefined);
  controller.destroy();
});

test("destroy removes touch, mouse and media listeners and cancels pending taps", () => {
  const { root, controls, video, tap, calls, timer, controller } = harness();
  tap(200);
  controller.destroy();
  calls.length = 0;
  tap(200);
  fire(root, "mousemove");
  fire(controls, "touchstart");
  fire(video, "pause");
  timer.tick(6000);
  assert.deepEqual(calls, []);
});

test("touching an interactive control cancels a pending background tap", () => {
  const h = harness();
  h.tap(200);
  const button = h.root.appendChild(new PlayerElement("BUTTON"));
  fire(h.root, "touchstart", { target: button, touches: [{ clientX: 400, clientY: 20 }] });
  h.timer.tick(1000);
  assert.deepEqual(h.calls, []);
  h.controller.destroy();
});

test("the blank controls overlay is a gesture surface while its buttons stay interactive", () => {
  const h = harness();
  h.controls.id = "player-controls";
  fire(h.root, "click", { target: h.controls, clientX: 950 });
  h.timer.tick(100);
  fire(h.root, "click", { target: h.controls, clientX: 950 });
  assert.deepEqual(h.calls, [10]);
  h.controller.destroy();
});
