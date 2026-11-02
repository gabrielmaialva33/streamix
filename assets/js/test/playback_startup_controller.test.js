import assert from "node:assert/strict";
import test from "node:test";
import { PlaybackStartupController } from "../player/playback_startup_controller.js";
import { clock } from "./support/playback_clock.js";

function harness({ rvfc = true } = {}) {
  const timerApi = clock();
  const frames = new Map();
  const video = new EventTarget();
  Object.assign(video, { currentTime: 0, paused: true, readyState: 0 });
  if (rvfc) {
    video.requestVideoFrameCallback = (fn) => {
      const id = frames.size + 1;
      frames.set(id, fn);
      return id;
    };
    video.cancelVideoFrameCallback = (id) => frames.delete(id);
  }
  const text = { textContent: "" };
  const root = { dataset: {}, querySelector: () => text };
  const stages = [];
  const controller = new PlaybackStartupController({
    root,
    video,
    timerApi,
    onFrame: () => stages.push("frame"),
    onMark: (mark) => stages.push(mark),
  });
  return { controller, video, root, timerApi, stages, frames, text };
}

test("metadata and playing keep preparation visible until a presented frame", () => {
  const h = harness();
  h.controller.begin();
  assert.equal(h.root.dataset.playerStage, "connecting");
  assert.equal(h.text.textContent, "Conectando…");
  h.video.dispatchEvent(new Event("loadedmetadata"));
  assert.equal(h.root.dataset.playerStage, "preparing");
  h.video.paused = false;
  h.video.dispatchEvent(new Event("playing"));
  assert.equal(h.controller.hasFrame, false);
  h.timerApi.advance(4000);
  assert.equal(h.root.dataset.playerStage, "slow");
  assert.equal(h.text.textContent, "Quase lá…");
  [...h.frames.values()][0]();
  assert.equal(h.root.dataset.playerStage, "playing");
  assert.equal(h.controller.hasFrame, true);
  assert.equal(h.stages.filter((stage) => stage === "frame").length, 1);
  h.controller.destroy();
});

test("fallback frame detection requires playing and positive time, and ignores metadata alone", () => {
  const h = harness({ rvfc: false });
  h.controller.begin();
  h.video.currentTime = 80; // resume seek is not a decoded frame
  h.video.readyState = 4;
  h.video.dispatchEvent(new Event("timeupdate"));
  assert.equal(h.controller.hasFrame, false);
  h.video.currentTime = 0;
  h.video.paused = false;
  h.video.dispatchEvent(new Event("playing"));
  assert.equal(h.controller.hasFrame, false);
  h.video.currentTime = 0.1;
  h.video.dispatchEvent(new Event("timeupdate"));
  assert.equal(h.controller.hasFrame, true);
  h.controller.recover();
  assert.equal(h.root.dataset.playerStage, "reconnecting");
  h.controller.destroy();
  h.timerApi.advance(100000);
  assert.equal(h.root.dataset.playerStage, "reconnecting");
});

test("old frame callbacks cannot complete a replacement source or destroyed player", () => {
  const h = harness();
  h.controller.begin();
  const stale = [...h.frames.values()][0];
  h.controller.attach();
  stale();
  assert.equal(h.controller.hasFrame, false);
  h.controller.destroy();
  for (const frame of h.frames.values()) frame();
  assert.equal(h.controller.hasFrame, false);
});

test("canvas engines reveal playback on a positive rendering/time tick, not play alone", () => {
  const h = harness();
  h.controller.begin();
  h.controller.attach({ native: false });
  h.controller.canvasProgress(0, true);
  h.controller.canvasProgress(30, false);
  assert.equal(h.controller.hasFrame, false);
  h.controller.canvasProgress(0.1, true);
  assert.equal(h.controller.hasFrame, true);
  h.controller.destroy();
});

test("startup cover stays dimmed through metadata, then hides on frame and is removed on destroy", () => {
  const h = harness();
  h.controller.destroy();
  let cover;
  const root = {
    dataset: { playerPoster: "/known-cover.jpg" },
    querySelector: () => h.text,
    prepend(node) {
      cover = node;
    },
    ownerDocument: {
      createElement: () => ({
        style: {},
        setAttribute() {},
        remove() {
          this.removed = true;
        },
      }),
    },
  };
  const controller = new PlaybackStartupController({ root, video: h.video, timerApi: h.timerApi });
  controller.begin();
  h.video.dispatchEvent(new Event("loadedmetadata"));
  assert.equal(cover.src, "/known-cover.jpg");
  assert.match(cover.style.filter, /blur/);
  assert.equal(cover.hidden, false);
  controller.presented();
  assert.equal(cover.hidden, true);
  controller.destroy();
  assert.equal(cover.removed, true);
});
