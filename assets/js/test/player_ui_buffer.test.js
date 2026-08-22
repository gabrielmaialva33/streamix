import assert from "node:assert/strict";
import test from "node:test";

import { PlayerUI } from "../player/player_ui.js";

function indicatorDouble() {
  return {
    className: "",
    removed: false,
    style: {},
    textContent: "",
    remove() {
      this.removed = true;
    },
  };
}

function playerUiDouble(indicator) {
  return {
    container: {
      querySelector(selector) {
        return selector === "#buffer-health" ? indicator : null;
      },
    },
    elements: { controls: null },
  };
}

test("removes buffer diagnostics from normal playback sessions", () => {
  const previousWindow = globalThis.window;
  globalThis.window = { __STREAMIX_DEBUG__: false };

  try {
    const indicator = indicatorDouble();

    PlayerUI.prototype.updateBufferHealthIndicator.call(playerUiDouble(indicator), 20);

    assert.equal(indicator.removed, true);
  } finally {
    globalThis.window = previousWindow;
  }
});

test("keeps buffer diagnostics available for explicit debug sessions", () => {
  const previousWindow = globalThis.window;
  globalThis.window = { __STREAMIX_DEBUG__: true };

  try {
    const indicator = indicatorDouble();

    PlayerUI.prototype.updateBufferHealthIndicator.call(playerUiDouble(indicator), 20);

    assert.equal(indicator.removed, false);
    assert.equal(indicator.textContent, "20s");
    assert.equal(indicator.style.opacity, "1");
  } finally {
    globalThis.window = previousWindow;
  }
});

test("exposes PiP only while the active engine supports it", () => {
  const classes = new Set(["hidden"]);
  const attributes = new Map([["aria-pressed", "false"]]);
  const pipButton = {
    classList: {
      toggle(name, force) {
        if (force) classes.add(name);
        else classes.delete(name);
      },
    },
    disabled: true,
    setAttribute(name, value) {
      attributes.set(name, value);
    },
    title: "Picture-in-picture",
  };
  const playerUI = {
    elements: { pipButton },
    updatePiPUI: PlayerUI.prototype.updatePiPUI,
  };

  PlayerUI.prototype.setPiPAvailable.call(playerUI, true);
  assert.equal(classes.has("hidden"), false);
  assert.equal(pipButton.disabled, false);

  PlayerUI.prototype.updatePiPUI.call(playerUI, true);
  assert.equal(attributes.get("aria-pressed"), "true");

  PlayerUI.prototype.setPiPAvailable.call(playerUI, false);
  assert.equal(classes.has("hidden"), true);
  assert.equal(pipButton.disabled, true);
  assert.equal(attributes.get("aria-pressed"), "false");
});
