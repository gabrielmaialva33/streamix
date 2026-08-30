import assert from "node:assert/strict";
import test from "node:test";

import { createPlaybackCommandHarness } from "./support/playback_command_harness.js";

test("enforces rate capability and the iOS native-HLS watch-party cap", () => {
  const harness = createPlaybackCommandHarness();

  harness.state.rateSupported = false;
  assert.equal(harness.controller.setPlaybackRate(1.5), false);
  assert.deepEqual(harness.calls.speed, [1]);
  assert.deepEqual(harness.calls.positions, [{ force: true }]);

  harness.state.rateSupported = true;
  harness.state.partyMode = true;
  harness.video.canPlayType = () => "maybe";

  assert.equal(harness.controller.setPlaybackRate("1.5"), true);
  assert.equal(harness.video.playbackRate, 1);
  assert.deepEqual(harness.calls.rates, [1]);
  assert.deepEqual(harness.calls.events, [
    { event: "playback_rate_changed", payload: { rate: 1 } },
  ]);
  assert.equal(harness.calls.notices.length, 1);

  assert.equal(harness.controller.setPlaybackRate(1.5, { remote: true }), true);
  assert.deepEqual(harness.calls.rates, [1]);
  assert.equal(harness.calls.events.length, 1);

  harness.state.partyMode = false;
  assert.equal(harness.controller.setPlaybackRate("1.25"), true);
  assert.equal(harness.video.playbackRate, 1.25);
  assert.deepEqual(harness.calls.rates, [1, 1.25]);
});

test("prefers native readings and bounds implausible managed durations", () => {
  const harness = createPlaybackCommandHarness({
    state: { expectedDuration: 7_200 },
  });

  harness.state.nativeEngine = {
    getCurrentTime: () => 12,
    getDuration: () => 90,
    isPlaying: () => true,
  };

  assert.equal(harness.controller.getCurrentTime(), 12);
  assert.equal(harness.controller.getDuration(), 90);
  assert.equal(harness.controller.isPaused(), false);

  harness.state.nativeEngine = null;
  harness.state.managedEngine = {
    getCurrentTime: () => 42,
    getDuration: () => 50_000,
    isPlaying: () => false,
  };
  harness.video.playbackRate = Number.NaN;

  assert.equal(harness.controller.getCurrentTime(), 42);
  assert.equal(harness.controller.getDuration(), 7_200);
  assert.equal(harness.controller.isPaused(), true);
  assert.equal(harness.controller.getPlaybackRate(), 1);
});

test("remote sync hold blocks only remote resume commands", async () => {
  let playCalls = 0;
  const harness = createPlaybackCommandHarness({
    state: { syncHeld: true },
  });

  harness.state.managedEngine = {
    isPlaying: () => false,
    play: async () => {
      playCalls += 1;
    },
    pause: async () => {},
  };

  assert.equal(await harness.controller.togglePlayPause({ remote: true }), false);
  assert.equal(playCalls, 0);

  assert.equal(await harness.controller.togglePlayPause(), undefined);
  assert.equal(playCalls, 1);
});

test("destroy is idempotent and leaves safe command/read defaults", async () => {
  const harness = createPlaybackCommandHarness();

  harness.controller.destroy();
  harness.controller.destroy();

  assert.equal(harness.controller.destroyed, true);
  assert.equal(await harness.controller.togglePlayPause(), false);
  assert.equal(harness.controller.toggleMute(), false);
  assert.equal(harness.controller.adjustVolume(0.1), false);
  assert.equal(harness.controller.seek(10), false);
  assert.equal(harness.controller.seekTo(10), false);
  assert.equal(harness.controller.setPlaybackRate(1.25), false);
  assert.equal(harness.controller.getCurrentTime(), 0);
  assert.equal(harness.controller.getDuration(), 0);
  assert.equal(harness.controller.getPlaybackRate(), 1);
  assert.equal(harness.controller.isPaused(), true);
});
