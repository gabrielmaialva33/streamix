import assert from "node:assert/strict";
import test from "node:test";
import {
  consumePlaybackIntent,
  createEngineWarmup,
  installPlaybackIntent,
} from "../player/playback_intent.js";

function button(dataset = {}, href = "") {
  return {
    dataset,
    closest(selector) {
      return selector.includes("data-stream-type") ||
        selector.includes("data-source-type") ||
        selector.includes("data-cover") ||
        selector.includes("phx-click")
        ? this
        : null;
    },
    getAttribute(name) {
      return name === "href" ? href : null;
    },
    querySelector() {
      return null;
    },
  };
}

test("intent imports only the likely engine and deduplicates concurrent hover/focus", async () => {
  const calls = [];
  const loaders = Object.fromEntries(
    ["native", "hls", "mpegts", "avplayer"].map((engine) => [
      engine,
      async () => calls.push(engine),
    ]),
  );
  const warm = createEngineWarmup({ loaders });
  await Promise.all([warm(button({ streamType: "hls" })), warm(button({ streamType: "hls" }))]);
  await warm(button({ streamType: "ts" }));
  await warm(button({ sourceType: "gindex" }));
  await warm(button({ streamType: "mp4" }));
  assert.deepEqual(calls, ["hls", "mpegts", "avplayer", "native"]);
});

test("hover/focus warm code without recording a click; matched click is consumed once", async () => {
  const listeners = new Map();
  const documentRef = {
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
  };
  const warmed = [];
  let now = 100;
  const dispose = installPlaybackIntent({
    documentRef,
    now: () => now,
    warm: (el) => warmed.push(el),
  });
  const target = button({ contentId: "42", cover: "/cover.jpg" });
  listeners.get("pointerover")({ target });
  listeners.get("focusin")({ target });
  assert.equal(warmed.length, 2);
  assert.equal(consumePlaybackIntent({ now: () => now }), null);
  listeners.get("click")({ target, button: 0 });
  now = 350;
  assert.deepEqual(consumePlaybackIntent({ contentId: "42", now: () => now }), {
    startedAt: 100,
    cover: "/cover.jpg",
  });
  assert.equal(consumePlaybackIntent({ now: () => now }), null);
  listeners.get("click")({ target, button: 0 });
  assert.equal(consumePlaybackIntent({ contentId: "99", now: () => now }), null);
  listeners.get("click")({ target, button: 0 });
  now += 30001;
  assert.equal(consumePlaybackIntent({ now: () => now }), null);
  dispose();
  assert.equal(listeners.size, 0);
});
