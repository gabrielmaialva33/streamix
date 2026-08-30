import assert from "node:assert/strict";
import test from "node:test";

import {
  createPlaybackCommandHarness,
  settleCommands,
} from "./support/playback_command_harness.js";

test("delegates managed play/pause and normalized audio commands", async () => {
  const harness = createPlaybackCommandHarness();
  let playing = false;
  let playCalls = 0;
  let pauseCalls = 0;

  harness.state.managedEngine = {
    isPlaying: () => playing,
    async play() {
      playCalls += 1;
      playing = true;
    },
    async pause() {
      pauseCalls += 1;
      playing = false;
    },
  };

  assert.equal(await harness.controller.togglePlayPause(), undefined);
  assert.equal(playCalls, 1);
  assert.deepEqual(harness.calls.states, ["playing"]);

  assert.equal(await harness.controller.togglePlayPause(), undefined);
  assert.equal(pauseCalls, 1);
  assert.deepEqual(harness.calls.states, ["playing", "paused"]);

  assert.equal(harness.controller.toggleMute(), undefined);
  assert.equal(harness.audio.muted, true);
  assert.equal(harness.controller.adjustVolume("0.2"), undefined);
  assert.equal(harness.audio.volume, 0.7);
  assert.deepEqual(harness.calls.events, [
    { event: "mute_toggled", payload: { muted: true } },
    { event: "volume_changed", payload: { volume: 70 } },
  ]);
  assert.equal(harness.controller.adjustVolume("invalid"), false);
});

test("denies local viewer commands before consulting an engine", async () => {
  let engineReads = 0;
  const harness = createPlaybackCommandHarness({
    state: { denied: true },
    boundaries: {
      getManagedPlaybackEngine() {
        engineReads += 1;
        return null;
      },
    },
  });

  assert.equal(await harness.controller.togglePlayPause(), false);
  assert.equal(harness.controller.seek(10), false);
  assert.equal(harness.controller.seekTo(30), false);
  assert.equal(harness.controller.setPlaybackRate(1.25), false);
  assert.equal(engineReads, 0);
});

test("contains engine failures even when diagnostics also fail", async () => {
  let diagnostics = 0;
  const harness = createPlaybackCommandHarness({
    boundaries: {
      onDebug() {
        diagnostics += 1;
        throw new Error("debug sink unavailable");
      },
      onError() {
        diagnostics += 1;
        throw new Error("error sink unavailable");
      },
    },
  });

  harness.state.managedEngine = {
    isPlaying: () => false,
    play: async () => {
      throw new Error("play rejected");
    },
    pause: async () => {},
    getCurrentTime: () => 10,
    getDuration: () => 100,
    seek() {
      throw new Error("seek rejected");
    },
  };

  assert.equal(await harness.controller.togglePlayPause(), false);
  assert.equal(harness.controller.seek(5), undefined);
  await settleCommands();
  assert.ok(diagnostics >= 2);
});

test("normalizes managed relative and absolute seeks", async () => {
  const seeks = [];
  const harness = createPlaybackCommandHarness();

  harness.state.managedEngine = {
    getCurrentTime: () => 20,
    getDuration: () => 100,
    isPlaying: () => true,
    seek(target) {
      seeks.push(target);
    },
  };

  assert.equal(harness.controller.seek("15"), undefined);
  assert.equal(harness.controller.seekTo("150"), undefined);
  await settleCommands();

  assert.deepEqual(seeks, [35, 100]);
  assert.deepEqual(harness.calls.positions, [{ force: true }, { force: true }]);
  assert.deepEqual(harness.calls.emitted, [{ target: harness.root, event: "seeked" }]);
});

test("keeps native VOD and live seek policies distinct", () => {
  let prepared = 0;
  const harness = createPlaybackCommandHarness({
    boundaries: {
      getNativeBufferingController: () => ({
        prepareSeek() {
          prepared += 1;
        },
      }),
    },
  });

  harness.video.currentTime = 20;
  assert.equal(harness.controller.seek(-50), undefined);
  assert.equal(harness.video.currentTime, 0);
  assert.equal(prepared, 1);

  harness.state.contentType = "live";
  harness.video.seekable = {
    length: 1,
    start: () => 5,
    end: () => 60,
  };

  assert.equal(harness.controller.seekTo(30), false);
  assert.equal(harness.controller.seekTo(100, { remote: true }), true);
  assert.ok(Math.abs(harness.video.currentTime - 59.95) < 0.000_001);
});
