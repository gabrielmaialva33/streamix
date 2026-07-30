import assert from "node:assert/strict";
import test from "node:test";

import {
  adjustAudioVolume,
  audioOutputVolume,
  hydrateAudioState,
  setAudioVolume,
  toggleAudioMute,
} from "../player/audio_state.js";

test("hydrates legacy persisted values into one canonical state", () => {
  assert.deepEqual(hydrateAudioState({ volume: "0.72", muted: "true" }), {
    volume: 0.72,
    muted: true,
    lastAudibleVolume: 0.72,
  });

  assert.deepEqual(hydrateAudioState({ volume: "invalid" }), {
    volume: 1,
    muted: false,
    lastAudibleVolume: 1,
  });
});

test("raising volume unmutes and remembers the audible value", () => {
  const state = setAudioVolume({ volume: 0, muted: true, lastAudibleVolume: 0.6 }, 0.35);

  assert.deepEqual(state, {
    volume: 0.35,
    muted: false,
    lastAudibleVolume: 0.35,
  });
});

test("mute toggle restores volume when the slider is at zero", () => {
  const state = toggleAudioMute({
    volume: 0,
    muted: false,
    lastAudibleVolume: 0.65,
  });

  assert.deepEqual(state, {
    volume: 0.65,
    muted: false,
    lastAudibleVolume: 0.65,
  });
});

test("volume adjustments clamp without corrupting mute state", () => {
  const initial = { volume: 0.8, muted: false, lastAudibleVolume: 0.8 };

  assert.deepEqual(adjustAudioVolume(initial, 0.5), {
    volume: 1,
    muted: false,
    lastAudibleVolume: 1,
  });

  assert.deepEqual(adjustAudioVolume(initial, -2), {
    volume: 0,
    muted: false,
    lastAudibleVolume: 0.8,
  });
});

test("output volume consistently applies mute and perceived loudness", () => {
  assert.equal(audioOutputVolume({ volume: 0.5, muted: false }), 0.25);
  assert.equal(audioOutputVolume({ volume: 0.5, muted: true }), 0);
});
