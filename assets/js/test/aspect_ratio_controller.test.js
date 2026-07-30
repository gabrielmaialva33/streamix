import assert from "node:assert/strict";
import test from "node:test";
import {
  aspectStyleForMode,
  createAspectRatioController,
  normalizeAspectMode,
} from "../player/aspect_ratio_controller.js";

test("normalizes stored aspect modes", () => {
  assert.equal(normalizeAspectMode("16-9"), "16-9");
  assert.equal(normalizeAspectMode("invalid"), "auto");
  assert.equal(normalizeAspectMode(null), "auto");
});

test("maps aspect modes to media element styles", () => {
  assert.deepEqual(aspectStyleForMode("cover"), { objectFit: "cover", aspectRatio: "" });
  assert.deepEqual(aspectStyleForMode("16-9"), {
    objectFit: "contain",
    aspectRatio: "16 / 9",
  });
  assert.deepEqual(aspectStyleForMode("native"), { objectFit: "none", aspectRatio: "" });
  assert.deepEqual(aspectStyleForMode("invalid"), { objectFit: "", aspectRatio: "" });
});

test("keeps working without storage and removes option listeners on destroy", () => {
  const button = new EventTarget();
  button.dataset = { aspectMode: "cover" };
  const video = { style: {} };
  const mountedVideo = { style: {} };
  const mount = {
    querySelectorAll() {
      return [mountedVideo];
    },
  };
  const check = {
    classList: {
      toggle(_className, hidden) {
        check.hidden = hidden;
      },
    },
    dataset: { aspectCheck: "cover" },
  };
  const root = {
    querySelector: () => mount,
    querySelectorAll(selector) {
      if (selector === ".aspect-option") return [button];
      if (selector === ".aspect-check") return [check];
      return [];
    },
  };
  const storage = {
    getItem() {
      throw new Error("storage disabled");
    },
    setItem() {
      throw new Error("storage disabled");
    },
  };
  let mutationCallback;

  class MutationObserverStub {
    constructor(callback) {
      mutationCallback = callback;
    }

    observe() {}
    disconnect() {}
  }

  const controller = createAspectRatioController({
    root,
    video,
    storage,
    MutationObserverImpl: MutationObserverStub,
  });

  button.dispatchEvent(new Event("click"));
  mutationCallback();
  assert.equal(video.style.objectFit, "cover");
  assert.equal(mountedVideo.style.objectFit, "cover");
  assert.equal(check.hidden, false);

  controller.destroy();
  button.dataset.aspectMode = "native";
  button.dispatchEvent(new Event("click"));
  assert.equal(video.style.objectFit, "cover");
});
