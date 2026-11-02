import assert from "node:assert/strict";
import test from "node:test";
import { createPlayerInteractions } from "../player/player_interactions.js";
import { clock, fire, PlayerElement } from "./player_controls_helpers.js";

function harness(options = {}) {
  const root = new PlayerElement();
  const video = root.appendChild(new PlayerElement("VIDEO"));
  const documentRef = new EventTarget();
  const timer = clock();
  const state = { paused: true, live: false };
  const calls = [];
  const controller = createPlayerInteractions({
    root,
    video,
    documentRef,
    scheduler: timer,
    now: timer.now,
    MutationObserverImpl: options.MutationObserverImpl ?? null,
    isPaused: () => state.paused,
    getContentType: () => (state.live ? "live" : "vod"),
    seek: (delta) => calls.push(delta),
    togglePlayPause: () => calls.push("play"),
    nextEpisode: () => calls.push("next"),
  });
  const click = (action) => {
    const button = root.appendChild(new PlayerElement("BUTTON"));
    button.dataset.playerAction = action;
    const icon = button.appendChild(new PlayerElement("SPAN"));
    return fire(root, "click", { target: icon });
  };
  return { root, video, documentRef, timer, state, calls, controller, click };
}

test("delegated nested clicks toggle panel, fit and lock; only unlock works locked", () => {
  const { root, click, calls, controller } = harness();
  click("episodes");
  assert.equal(root.dataset.playerPanel, "episodes");
  click("episodes");
  assert.equal(root.dataset.playerPanel, undefined);
  click("episodes");
  click("close-panel");
  assert.equal(root.dataset.playerPanel, undefined);
  click("fit-toggle");
  assert.equal(root.dataset.playerFit, "fill");
  click("fit-toggle");
  assert.equal(root.dataset.playerFit, undefined);
  click("lock");
  assert.equal(root.dataset.playerLocked, "true");
  for (const action of ["seek-forward", "toggle-play", "next-episode", "episodes", "fit-toggle"])
    click(action);
  assert.equal(root.dataset.playerPanel, undefined);
  assert.equal(root.dataset.playerFit, undefined);
  assert.deepEqual(calls, []);
  click("unlock");
  assert.equal(root.dataset.playerLocked, undefined);
  click("toggle-play");
  click("next-episode");
  assert.deepEqual(calls, ["play", "next"]);
  controller.destroy();
});

test("seek buttons show signed accumulated feedback and obey live/viewer policy", () => {
  const { root, click, calls, state, timer, controller } = harness();
  click("seek-backward");
  timer.tick(200);
  click("seek-backward");
  const bubble = root.querySelector(".player-seek-feedback");
  assert.equal(bubble.dataset.side, "left");
  assert.equal(bubble.dataset.visible, "true");
  assert.equal(bubble.querySelector(".player-seek-feedback-label").textContent, "−20 s");
  timer.tick(700);
  assert.equal(bubble.dataset.visible, "false");
  click("seek-forward");
  assert.deepEqual(calls, [-10, -10, 10]);
  state.live = true;
  click("seek-forward");
  root.dataset.partyRole = "viewer";
  for (const action of ["seek-backward", "toggle-play", "next-episode", "episodes"]) click(action);
  assert.deepEqual(calls, [-10, -10, 10]);
  controller.destroy();
  assert.equal(timer.pending, 0);
});

test("pause screen waits six seconds, resets on document keys and clears on play", () => {
  const { root, documentRef, timer, video, state, controller } = harness();
  timer.tick(5999);
  assert.equal(root.dataset.playerIdlePaused, undefined);
  fire(documentRef, "keydown");
  timer.tick(5999);
  assert.equal(root.dataset.playerIdlePaused, undefined);
  timer.tick(1);
  assert.equal(root.dataset.playerIdlePaused, "true");
  fire(root, "pointermove");
  assert.equal(root.dataset.playerIdlePaused, undefined);
  timer.tick(6000);
  assert.equal(root.dataset.playerIdlePaused, "true");
  state.paused = false;
  fire(video, "play");
  assert.equal(root.dataset.playerIdlePaused, undefined);
  timer.tick(6000);
  assert.equal(root.dataset.playerIdlePaused, undefined);
  controller.destroy();
});

test("pause screen excludes live, viewers, panels, errors and ended overlays", () => {
  for (const exclusion of ["live", "viewer", "panel", "error", "ended"]) {
    const h = harness();
    if (exclusion === "live") h.state.live = true;
    if (exclusion === "viewer") h.root.dataset.partyRole = "viewer";
    if (exclusion === "panel") h.click("episodes");
    if (["error", "ended"].includes(exclusion)) {
      const overlay = h.root.appendChild(new PlayerElement());
      overlay.id = exclusion === "error" ? "error-container" : "ended-overlay";
    }
    h.timer.tick(6000);
    assert.equal(h.root.dataset.playerIdlePaused, undefined, exclusion);
    h.controller.destroy();
  }
});

test("teardown removes actions, pause timers and feedback elements", () => {
  const { click, controller, root, timer, calls } = harness();
  click("seek-forward");
  controller.destroy();
  click("toggle-play");
  timer.tick(10000);
  assert.deepEqual(calls, [10]);
  assert.equal(root.querySelector(".player-seek-feedback"), null);
  assert.equal(root.dataset.playerIdlePaused, undefined);
  assert.equal(timer.pending, 0);
});

test("overlay mutations clear an active pause screen and resume the six-second wait", () => {
  let notify;
  let disconnected = false;
  class Observer {
    constructor(callback) {
      notify = callback;
    }
    observe() {}
    disconnect() {
      disconnected = true;
    }
  }
  const h = harness({ MutationObserverImpl: Observer });
  h.timer.tick(6000);
  assert.equal(h.root.dataset.playerIdlePaused, "true");
  const error = h.root.appendChild(new PlayerElement());
  error.id = "error-container";
  notify();
  assert.equal(h.root.dataset.playerIdlePaused, undefined);
  error.classList.add("hidden");
  notify();
  h.timer.tick(5999);
  assert.equal(h.root.dataset.playerIdlePaused, undefined);
  h.timer.tick(1);
  assert.equal(h.root.dataset.playerIdlePaused, "true");
  h.state.paused = false;
  fire(h.root, "streamix:playback", { detail: { type: "play" } });
  assert.equal(h.root.dataset.playerIdlePaused, undefined);
  h.controller.destroy();
  assert.equal(disconnected, true);
});

test("seek feedback stays accumulated at the exact 700ms chain boundary", () => {
  const h = harness();
  h.click("seek-forward");
  h.timer.tick(700);
  h.click("seek-forward");
  const bubble = h.root.querySelector(".player-seek-feedback");
  assert.equal(bubble.querySelector(".player-seek-feedback-label").textContent, "+20 s");
  h.controller.destroy();
});
