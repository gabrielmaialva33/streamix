import assert from "node:assert/strict";
import test from "node:test";

import {
  assertPlaybackEngine,
  PLAYBACK_ENGINE_CAPABILITY_METHODS,
  PLAYBACK_ENGINE_METHODS,
  PLAYBACK_ENGINE_REQUIRED_METHODS,
  playbackEngineCapabilities,
  playbackEngineViolations,
} from "../player/engine_contract.js";

function minimalEngine(overrides = {}) {
  return {
    load() {},
    play() {},
    pause() {},
    seek() {},
    destroy() {},
    ...overrides,
  };
}

test("publishes one immutable source of truth for the engine surface", () => {
  assert.equal(Object.isFrozen(PLAYBACK_ENGINE_REQUIRED_METHODS), true);
  assert.equal(Object.isFrozen(PLAYBACK_ENGINE_CAPABILITY_METHODS), true);
  assert.equal(Object.isFrozen(PLAYBACK_ENGINE_METHODS), true);
  assert.deepEqual(PLAYBACK_ENGINE_REQUIRED_METHODS, ["load", "play", "pause", "seek", "destroy"]);
  assert.equal(new Set(PLAYBACK_ENGINE_METHODS).size, PLAYBACK_ENGINE_METHODS.length);
});

test("reports invalid objects and every missing required method", () => {
  assert.deepEqual(playbackEngineViolations(null), ["engine must be an object"]);
  assert.deepEqual(playbackEngineViolations({ load() {} }), [
    "missing method play()",
    "missing method pause()",
    "missing method seek()",
    "missing method destroy()",
  ]);
});

test("asserts the contract with a caller-specific diagnostic name", () => {
  const engine = minimalEngine();
  assert.equal(assertPlaybackEngine(engine), engine);

  assert.throws(
    () => assertPlaybackEngine(null, { name: "TestEngine" }),
    /TestEngine requires an engine object/,
  );
  assert.throws(
    () => assertPlaybackEngine({ load() {} }, { name: "TestEngine" }),
    /TestEngine is missing required methods: play, pause, seek, destroy/,
  );
});

test("capabilities are bounded, immutable, and separate from required methods", () => {
  const capabilities = playbackEngineCapabilities(
    minimalEngine({
      setVolume() {},
      getCurrentTime() {},
      snapshot() {},
    }),
  );

  assert.equal(Object.isFrozen(capabilities), true);
  assert.equal(capabilities.setVolume, true);
  assert.equal(capabilities.getCurrentTime, true);
  assert.equal(capabilities.snapshot, true);
  assert.equal(capabilities.getDuration, false);
  assert.equal(capabilities.getAudioTracks, false);
  assert.equal(Object.hasOwn(capabilities, "load"), false);
});
