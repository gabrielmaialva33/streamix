import assert from "node:assert/strict";
import test from "node:test";
import { KeyboardManager } from "../core/keyboard_manager.js";

function harness() {
  const calls = [];
  const root = { dataset: {} };
  const manager = new KeyboardManager({
    contentType: "vod",
    root,
    actions: {
      togglePlayPause: () => calls.push("play"),
      isPaused: () => true,
      toggleMute: () => calls.push("mute"),
      isMuted: () => false,
      toggleFullscreen: () => calls.push("fullscreen"),
      exitFullscreen: () => calls.push("exit"),
      nextEpisode: () => calls.push("next"),
      adjustVolume: (delta) => calls.push(delta),
      seek: (delta) => calls.push(delta),
    },
  });
  const key = (value, target = { tagName: "DIV" }, extra = {}) => {
    const event = {
      key: value,
      target,
      preventDefault() {
        this.defaultPrevented = true;
      },
      ...extra,
    };
    manager.handleKeyDown(event);
    return event;
  };
  return { manager, root, calls, key };
}

test("Netflix keys route transport, volume, fullscreen and next episode", () => {
  const { key, calls } = harness();
  for (const value of [
    " ",
    "Enter",
    "f",
    "Escape",
    "ArrowLeft",
    "ArrowRight",
    "ArrowUp",
    "ArrowDown",
    "m",
    "N",
  ])
    key(value);
  assert.deepEqual(calls, [
    "play",
    "play",
    "fullscreen",
    "exit",
    -10,
    10,
    0.1,
    -0.1,
    "mute",
    "next",
  ]);
});

test("Escape closes a panel before exiting fullscreen", () => {
  const { key, root, calls } = harness();
  root.dataset.playerPanel = "episodes";
  key("Escape");
  assert.equal(root.dataset.playerPanel, undefined);
  assert.deepEqual(calls, []);
});

test("locked screen, editable fields, modifiers and prevented events ignore shortcuts", () => {
  const { key, root, calls } = harness();
  for (const tagName of ["INPUT", "SELECT", "TEXTAREA"]) key(" ", { tagName });
  key("Enter", { isContentEditable: true });
  key(" ", undefined, { ctrlKey: true });
  key(" ", undefined, { defaultPrevented: true });
  root.dataset.playerLocked = "true";
  for (const value of [" ", "Enter", "f", "Escape", "ArrowRight", "ArrowUp", "m", "n"]) key(value);
  assert.deepEqual(calls, []);
});

test("live blocks seeking; party viewers block transport but retain local audio", () => {
  const { manager, key, root, calls } = harness();
  manager.setContentType("live");
  key("ArrowLeft");
  key("ArrowRight");
  manager.setContentType("vod");
  root.dataset.partyRole = "viewer";
  for (const value of [" ", "Enter", "ArrowLeft", "ArrowRight", "n"]) key(value);
  key("m");
  key("ArrowUp");
  assert.deepEqual(calls, ["mute", 0.1]);
});

test("Enter on a button preserves its native activation instead of toggling playback", () => {
  const { key, calls } = harness();
  assert.equal(
    key("Enter", { tagName: "BUTTON", closest: () => ({}) }).defaultPrevented,
    undefined,
  );
  assert.deepEqual(calls, []);
});
