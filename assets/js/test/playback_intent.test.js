import assert from "node:assert/strict";
import test from "node:test";
import {
  consumePlaybackIntent,
  createEngineWarmup,
  installPlaybackIntent,
  warmPrimaryPlayback,
} from "../player/playback_intent.js";
import { recordPlayerSuccess } from "../player/player_preferences.js";

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

test("intent warms the remembered provider/container engine without affecting other providers or TS", async (t) => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  const values = new Map();
  globalThis.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "localStorage", previous);
    else delete globalThis.localStorage;
  });
  recordPlayerSuccess("provider:3:mp4", "avplayer");
  recordPlayerSuccess("provider:3:mp4", "avplayer");
  const calls = [];
  const warm = createEngineWarmup({
    loaders: Object.fromEntries(
      ["native", "hls", "mpegts", "avplayer"].map((engine) => [
        engine,
        async () => calls.push(engine),
      ]),
    ),
  });
  await warm(button({ streamType: "mp4", providerId: "3" }));
  assert.deepEqual(calls, ["avplayer"]);
  await warm(button({ streamType: "mp4", providerId: "4" }));
  await warm(button({ streamType: "ts", providerId: "3" }));
  assert.deepEqual(calls, ["avplayer", "native", "mpegts"]);
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
  const target = button({ contentId: "42", providerId: "3", cover: "/cover.jpg" });
  listeners.get("pointerover")({ target });
  listeners.get("focusin")({ target });
  assert.equal(warmed.length, 2);
  assert.equal(consumePlaybackIntent({ now: () => now }), null);
  listeners.get("click")({ target, button: 0 });
  now = 350;
  assert.deepEqual(consumePlaybackIntent({ contentId: "42", now: () => now }), {
    startedAt: 100,
    cover: "/cover.jpg",
    providerId: "3",
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

test("a title page warms its play button's engine once idle, again after each navigation", () => {
  const primary = button({ streamType: "mkv", sourceType: "gindex", providerId: "2" });
  let current = primary;
  const documentRef = {
    addEventListener: () => {},
    removeEventListener: () => {},
    querySelector: (selector) => (selector === "[data-playback-warm]" ? current : null),
  };
  const windowListeners = new Map();
  const windowRef = {
    addEventListener: (name, fn) => windowListeners.set(name, fn),
    removeEventListener: (name) => windowListeners.delete(name),
  };
  const idle = [];
  const warmed = [];

  const dispose = installPlaybackIntent({
    documentRef,
    windowRef,
    warm: (element) => warmed.push(element),
    schedule: (callback) => idle.push(callback),
  });

  // Nothing heavy runs before the page is idle.
  assert.deepEqual(warmed, []);
  idle.shift()();
  assert.deepEqual(warmed, [primary]);

  // A LiveView navigation to another title warms that title's button.
  const next = button({ streamType: "mp4", providerId: "3" });
  current = next;
  windowListeners.get("phx:page-loading-stop")();
  idle.shift()();
  assert.deepEqual(warmed, [primary, next]);

  dispose();
  assert.equal(windowListeners.size, 0);
});

test("a page without a marked play button warms nothing", () => {
  const scheduled = [];
  assert.equal(
    warmPrimaryPlayback({
      documentRef: { querySelector: () => null },
      warm: () => assert.fail("must not warm"),
      schedule: (callback) => scheduled.push(callback),
    }),
    false,
  );
  assert.deepEqual(scheduled, []);
});
