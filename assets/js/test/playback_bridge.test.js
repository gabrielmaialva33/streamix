import assert from "node:assert/strict";
import test from "node:test";

import {
  emitPlaybackEvent,
  installPlaybackBridge,
  PLAYBACK_BRIDGE_EVENT,
} from "../player/playback_bridge.js";

function fakeElement() {
  const listeners = new Map();

  return {
    listeners,
    addEventListener(type, handler) {
      listeners.set(type, [...(listeners.get(type) || []), handler]);
    },
    dispatchEvent(event) {
      for (const handler of listeners.get(event.type) || []) handler(event);
      return true;
    },
  };
}

function fakeHook(overrides = {}) {
  return {
    usingAVPlayer: false,
    usingAvbridge: false,
    usingH265web: false,
    paused: true,
    playbackRate: 1,
    time: 0,
    seeked: [],
    rates: [],
    toggles: 0,
    getCurrentTime() {
      return this.time;
    },
    getDuration() {
      return 100;
    },
    isPaused() {
      return this.paused;
    },
    seekTo(time) {
      this.seeked.push(time);
    },
    togglePlayPause() {
      this.toggles += 1;
      this.paused = !this.paused;
    },
    getPlaybackRate() {
      return this.usingAVPlayer || this.usingH265web ? 1 : this.playbackRate;
    },
    setPlaybackRate(rate) {
      if (this.usingAVPlayer || this.usingH265web) return false;
      this.rates.push(rate);
      this.playbackRate = rate;
      return true;
    },
    ...overrides,
  };
}

test("reports the engine currently driving playback", () => {
  const el = fakeElement();
  const hook = fakeHook();
  installPlaybackBridge(el, hook);

  assert.equal(el.streamixPlayback.engine, "native");

  hook.usingAvbridge = true;
  assert.equal(el.streamixPlayback.engine, "avbridge");

  hook.usingAvbridge = false;
  hook.usingH265web = true;
  assert.equal(el.streamixPlayback.engine, "h265web");

  hook.usingH265web = false;
  hook.usingAVPlayer = true;
  assert.equal(el.streamixPlayback.engine, "avplayer");
});

test("reads position and paused state through the hook, not the video element", () => {
  const el = fakeElement();
  // An AVPlayer session leaves the native <video> parked at 0s/paused —
  // only the hook knows the real playhead.
  const hook = fakeHook({ usingAVPlayer: true, paused: false, time: 42.5 });
  installPlaybackBridge(el, hook);

  assert.equal(el.streamixPlayback.getCurrentTime(), 42.5);
  assert.equal(el.streamixPlayback.isPaused(), false);
});

test("play and pause are idempotent against the current state", () => {
  const el = fakeElement();
  const hook = fakeHook({ paused: true });
  installPlaybackBridge(el, hook);

  el.streamixPlayback.play();
  el.streamixPlayback.play();
  assert.equal(hook.toggles, 1, "already playing — must not toggle back to paused");

  el.streamixPlayback.pause();
  el.streamixPlayback.pause();
  assert.equal(hook.toggles, 2);
});

test("declines playback rate changes on AVPlayer, which has no rate knob", () => {
  const el = fakeElement();
  const hook = fakeHook({ usingAVPlayer: true });
  installPlaybackBridge(el, hook);

  assert.equal(el.streamixPlayback.setPlaybackRate(1.1), false);
  assert.deepEqual(hook.rates, []);

  hook.usingAVPlayer = false;
  hook.usingH265web = true;
  assert.equal(el.streamixPlayback.setPlaybackRate(1.1), false);
  assert.deepEqual(hook.rates, []);

  hook.usingH265web = false;
  assert.equal(el.streamixPlayback.setPlaybackRate(1.1), true);
  assert.equal(el.streamixPlayback.getPlaybackRate(), 1.1);
  assert.deepEqual(hook.rates, [1.1]);
});

test("emits state changes with the engine-agnostic position", () => {
  const el = fakeElement();
  const hook = fakeHook({ usingAVPlayer: true, time: 12 });
  installPlaybackBridge(el, hook);

  const seen = [];
  el.addEventListener(PLAYBACK_BRIDGE_EVENT, (event) => seen.push(event.detail));

  emitPlaybackEvent(el, "seeked");

  assert.deepEqual(seen, [{ type: "seeked", position: 12 }]);
});

test("disposing removes the bridge so a stale player cannot be steered", () => {
  const el = fakeElement();
  const dispose = installPlaybackBridge(el, fakeHook());

  dispose();

  assert.equal(el.streamixPlayback, undefined);
});
