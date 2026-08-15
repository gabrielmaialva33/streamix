import assert from "node:assert/strict";
import test from "node:test";
import {
  aspectStyleForMode,
  createAspectRatioController,
  normalizeAspectMode,
} from "../player/aspect_ratio_controller.js";

function fakeElement() {
  const properties = {};

  return {
    properties,
    style: {
      setProperty(name, value) {
        properties[name] = value;
      },
    },
  };
}

test("normalizes stored aspect modes", () => {
  assert.equal(normalizeAspectMode("16-9"), "16-9");
  assert.equal(normalizeAspectMode("invalid"), "auto");
  assert.equal(normalizeAspectMode(null), "auto");
});

test("maps aspect modes to media element styles", () => {
  assert.deepEqual(aspectStyleForMode("cover"), {
    objectFit: "cover",
    aspectRatio: "",
    width: "",
    height: "",
  });
  assert.deepEqual(aspectStyleForMode("16-9"), {
    objectFit: "fill",
    aspectRatio: "16 / 9",
    width: "auto",
    height: "auto",
  });
  assert.deepEqual(aspectStyleForMode("native"), {
    objectFit: "none",
    aspectRatio: "",
    width: "",
    height: "",
  });
  assert.deepEqual(aspectStyleForMode("invalid"), {
    objectFit: "",
    aspectRatio: "",
    width: "",
    height: "",
  });
});

test("keeps working without storage and removes option listeners on destroy", () => {
  const button = new EventTarget();
  button.dataset = { aspectMode: "cover" };
  const video = fakeElement();
  const avplayerCanvas = fakeElement();
  const h265webCanvas = fakeElement();
  const mounts = {
    "#avplayer-mount": { querySelectorAll: () => [avplayerCanvas] },
    "#h265web-mount": { querySelectorAll: () => [h265webCanvas] },
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
    querySelector: (selector) => mounts[selector] ?? null,
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
  const mutationCallbacks = [];

  class MutationObserverStub {
    constructor(callback) {
      mutationCallbacks.push(callback);
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
  assert.equal(mutationCallbacks.length, 2);
  for (const callback of mutationCallbacks) {
    callback();
  }

  assert.equal(video.style.objectFit, "cover");
  assert.equal(avplayerCanvas.style.objectFit, "cover");
  assert.equal(h265webCanvas.style.objectFit, "cover");
  assert.equal(check.hidden, false);

  controller.destroy();
  button.dataset.aspectMode = "native";
  button.dispatchEvent(new Event("click"));
  assert.equal(video.style.objectFit, "cover");
});

test("drives canvas players through custom properties and frees the box for forced ratios", () => {
  const button = new EventTarget();
  button.dataset = { aspectMode: "16-9" };
  const avplayerCanvas = fakeElement();
  const root = {
    querySelector: (selector) =>
      selector === "#avplayer-mount" ? { querySelectorAll: () => [avplayerCanvas] } : null,
    querySelectorAll(selector) {
      if (selector === ".aspect-option") return [button];
      return [];
    },
  };

  createAspectRatioController({
    root,
    video: null,
    storage: null,
    MutationObserverImpl: null,
  });

  button.dispatchEvent(new Event("click"));

  assert.equal(avplayerCanvas.properties["--streamix-player-fit"], "fill");
  assert.equal(avplayerCanvas.properties["--streamix-player-width"], "auto");
  assert.equal(avplayerCanvas.properties["--streamix-player-height"], "auto");
  assert.equal(avplayerCanvas.style.aspectRatio, "16 / 9");
  assert.equal(avplayerCanvas.style.margin, "auto");
  assert.equal(avplayerCanvas.style.maxWidth, "100%");
});
