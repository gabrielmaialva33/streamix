import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_BRIDGE_EVENT } from "../player/playback_bridge.js";
import {
  BUFFERING_EVENT,
  createWatchPartyPlayerBinding,
  PLAYER_POLL_FAST_MS,
  PLAYER_POLL_SLOW_MS,
} from "../watch_party/player_binding.js";

class FakeElement extends EventTarget {
  constructor() {
    super();
    this.listenerCount = 0;
  }
  addEventListener(type, handler, options) {
    this.listenerCount += 1;
    super.addEventListener(type, handler, options);
  }
  removeEventListener(type, handler, options) {
    this.listenerCount -= 1;
    super.removeEventListener(type, handler, options);
  }
}

function createTimerApi() {
  const timers = new Map();
  let nextId = 1;
  return {
    setTimeout(callback, delay) {
      const id = nextId++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    pending: () => [...timers.values()].map((timer) => timer.delay),
    fire() {
      for (const [id, timer] of [...timers.entries()]) {
        timers.delete(id);
        timer.callback();
      }
    },
  };
}

function createPage({ withBridge = true, withVideo = true, nativeHls = false } = {}) {
  const playerEl = new FakeElement();
  const videoEl = new FakeElement();
  videoEl.canPlayType = (mime) =>
    nativeHls && mime === "application/vnd.apple.mpegurl" ? "maybe" : "";
  playerEl.querySelector = (selector) => (selector === "video" && withVideo ? videoEl : null);
  const holds = [];
  const bridge = {
    getCurrentTime: () => 12,
    isPaused: () => false,
    setSyncHold: (held) => {
      holds.push(held);
      return true;
    },
  };
  if (withBridge) playerEl.streamixPlayback = bridge;
  const documentRef = {
    getElementById: (id) => (id === "video-player-container" ? playerEl : null),
  };
  return { bridge, documentRef, holds, playerEl, videoEl };
}

function createHarness(pageOptions = {}, bindingOptions = {}) {
  const page = createPage(pageOptions);
  const timerApi = createTimerApi();
  const calls = { bound: 0, buffering: [], host: [] };
  const state = { destroyed: false, forward: true, hold: true };
  const owner = { id: "sync-hook" };
  const binding = createWatchPartyPlayerBinding({
    documentRef: page.documentRef,
    getSyncHold: () => state.hold,
    isDestroyed: () => state.destroyed,
    onBound: () => {
      calls.bound += 1;
    },
    onBuffering: (buffering) => calls.buffering.push(buffering),
    onHostPlaybackEvent: (event, position) => calls.host.push([event, position]),
    owner,
    shouldForwardHostEvent: () => state.forward,
    timerApi,
    ...bindingOptions,
  });
  return { binding, calls, owner, page, state, timerApi };
}

test("requires the buffering callback and stays unbound without a bridge or video", () => {
  assert.throws(() => createWatchPartyPlayerBinding({}), /requires onBuffering\(\)/);

  const noBridge = createHarness({ withBridge: false });
  assert.equal(noBridge.binding.ensure(), false);
  assert.equal(noBridge.binding.bound, false);

  const noVideo = createHarness({ withVideo: false });
  assert.equal(noVideo.binding.ensure(), false);
  assert.equal(noVideo.binding.position(), 0);
  assert.equal(noVideo.binding.isPaused(), true);
});

test("binding adopts the bridge, applies the hold, marks the owner and reports readiness", () => {
  const { binding, calls, owner, page } = createHarness({ nativeHls: true });

  assert.equal(binding.ensure(), true);
  assert.equal(binding.bound, true);
  assert.equal(binding.playback, page.bridge);
  assert.equal(binding.playerEl, page.playerEl);
  assert.equal(binding.videoEl, page.videoEl);
  assert.equal(binding.nativeHlsPlayback, true);
  assert.equal(page.playerEl.__watchPartySyncHook, owner);
  assert.deepEqual(page.holds, [true]);
  assert.equal(calls.bound, 1);
  assert.equal(binding.position(), 12);
  assert.equal(binding.isPaused(), false);

  assert.equal(binding.ensure(), true, "a stable binding is not rebound");
  assert.equal(calls.bound, 1);
  assert.equal(
    page.playerEl.listenerCount,
    1,
    "viewers only listen for buffering on the container",
  );
  assert.equal(page.videoEl.listenerCount, 3);
});

test("media and bridge buffering signals reach the owner and host events are gated", () => {
  const { binding, calls, page, state } = createHarness({}, { isHost: true });
  binding.ensure();

  page.videoEl.dispatchEvent(new Event("waiting"));
  page.videoEl.dispatchEvent(new Event("canplay"));
  page.videoEl.dispatchEvent(new Event("playing"));
  page.playerEl.dispatchEvent(new CustomEvent(BUFFERING_EVENT, { detail: { buffering: true } }));
  page.playerEl.dispatchEvent(new CustomEvent(BUFFERING_EVENT, { detail: { buffering: "yes" } }));
  assert.deepEqual(calls.buffering, [true, false, false, true]);

  page.playerEl.dispatchEvent(new CustomEvent(PLAYBACK_BRIDGE_EVENT, { detail: { type: "play" } }));
  page.playerEl.dispatchEvent(
    new CustomEvent(PLAYBACK_BRIDGE_EVENT, { detail: { type: "seeked" } }),
  );
  page.playerEl.dispatchEvent(
    new CustomEvent(PLAYBACK_BRIDGE_EVENT, { detail: { type: "volume" } }),
  );
  state.forward = false;
  page.playerEl.dispatchEvent(
    new CustomEvent(PLAYBACK_BRIDGE_EVENT, { detail: { type: "pause" } }),
  );
  assert.deepEqual(calls.host, [
    ["wp_play", 12],
    ["wp_seek", 12],
  ]);
  assert.equal(page.playerEl.listenerCount, 2, "hosts also listen to the playback bridge");
});

test("a replaced bridge or foreign owner marker triggers a clean rebind", () => {
  const { binding, calls, owner, page } = createHarness();
  binding.ensure();

  page.playerEl.__watchPartySyncHook = { id: "other" };
  assert.equal(binding.ensure(), true);
  assert.equal(calls.bound, 2);
  assert.equal(page.playerEl.__watchPartySyncHook, owner);
  assert.equal(page.videoEl.listenerCount, 3, "old listeners are removed before rebinding");

  const replacement = { ...page.bridge, getCurrentTime: () => 99 };
  page.playerEl.streamixPlayback = replacement;
  assert.equal(binding.ensure(), true);
  assert.equal(binding.playback, replacement);
  assert.equal(calls.bound, 3);
  assert.deepEqual(page.holds, [true, false, true, false, true], "each unbind releases the hold");
});

test("unbind releases the hold, listeners and owner marker exactly once", () => {
  const { binding, page } = createHarness();
  binding.ensure();

  assert.equal(binding.unbind(), true);
  assert.equal(binding.unbind(), false);
  assert.equal(binding.bound, false);
  assert.equal(page.playerEl.__watchPartySyncHook, undefined);
  assert.equal(page.playerEl.listenerCount, 0);
  assert.equal(page.videoEl.listenerCount, 0);
  assert.deepEqual(page.holds, [true, false]);

  page.videoEl.dispatchEvent(new Event("waiting"));
});

test("waitForPlayer polls fast, then slow, and stops once bound or destroyed", () => {
  const { binding, calls, page, state, timerApi } = createHarness({ withBridge: false });

  assert.equal(binding.waitForPlayer(0), false);
  assert.deepEqual(timerApi.pending(), [PLAYER_POLL_FAST_MS]);
  timerApi.fire();
  assert.deepEqual(timerApi.pending(), [PLAYER_POLL_FAST_MS]);

  assert.equal(binding.waitForPlayer(50), false);
  assert.deepEqual(timerApi.pending(), [PLAYER_POLL_SLOW_MS], "slow polling after the fast window");

  page.playerEl.streamixPlayback = page.bridge;
  timerApi.fire();
  assert.equal(binding.bound, true);
  assert.equal(calls.bound, 1);
  assert.deepEqual(timerApi.pending(), []);

  state.destroyed = true;
  assert.equal(binding.waitForPlayer(0), false);
  assert.equal(binding.ensure(), false);
  binding.destroy();
  assert.equal(binding.bound, false);
});
