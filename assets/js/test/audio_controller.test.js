import assert from "node:assert/strict";
import test from "node:test";

import { createAudioController } from "../player/audio_controller.js";

function buildController(initialPreferences = {}) {
  const applied = [];
  const rendered = [];
  const persisted = [];

  const controller = createAudioController({
    initialPreferences,
    applyOutput: (snapshot) => applied.push(snapshot),
    render: (state) => rendered.push(state),
    saveVolume: (volume) => persisted.push(["volume", volume]),
    saveMuted: (muted) => persisted.push(["muted", muted]),
  });

  return { controller, applied, rendered, persisted };
}

test("raising stored muted volume synchronizes one audible state everywhere", () => {
  const { controller, applied, rendered, persisted } = buildController({
    volume: 0.72,
    muted: true,
  });

  controller.setVolume(0.4);

  assert.deepEqual(controller.getState(), {
    volume: 0.4,
    muted: false,
    lastAudibleVolume: 0.4,
  });
  assert.equal(applied.at(-1).volume, 0.4);
  assert.equal(applied.at(-1).muted, false);
  assert.ok(Math.abs(applied.at(-1).outputVolume - 0.16) < 1.0e-12);
  assert.deepEqual(rendered.at(-1), {
    volume: 0.4,
    muted: false,
    lastAudibleVolume: 0.4,
  });
  assert.deepEqual(Object.fromEntries(persisted), {
    volume: 0.4,
    muted: false,
  });
});

test("toggling a zero-volume state restores an audible value", () => {
  const { controller, applied, persisted } = buildController({
    volume: 0,
    muted: false,
  });

  controller.toggleMute();

  assert.deepEqual(controller.getState(), {
    volume: 1,
    muted: false,
    lastAudibleVolume: 1,
  });
  assert.deepEqual(applied.at(-1), {
    volume: 1,
    outputVolume: 1,
    muted: false,
  });
  assert.deepEqual(Object.fromEntries(persisted), {
    volume: 1,
    muted: false,
  });
});

test("native controls update canonical state using the inverse volume curve", () => {
  const { controller, applied, persisted } = buildController({
    volume: 1,
    muted: false,
  });

  const changed = controller.syncNativeState({
    outputVolume: 0.25,
    muted: true,
  });

  assert.equal(changed, true);
  assert.deepEqual(controller.getState(), {
    volume: 0.5,
    muted: true,
    lastAudibleVolume: 0.5,
  });
  assert.deepEqual(applied.at(-1), {
    volume: 0.5,
    outputVolume: 0,
    muted: true,
  });
  assert.deepEqual(Object.fromEntries(persisted), {
    volume: 0.5,
    muted: true,
  });
});

test("matching native state does not rewrite preferences or outputs", () => {
  const { controller, applied, rendered, persisted } = buildController({
    volume: 0.5,
    muted: false,
  });

  const changed = controller.syncNativeState({
    outputVolume: 0.25,
    muted: false,
  });

  assert.equal(changed, false);
  assert.deepEqual(applied, []);
  assert.deepEqual(rendered, []);
  assert.deepEqual(persisted, []);
});

test("replacing restored state does not rewrite preferences", () => {
  const { controller, applied, rendered, persisted } = buildController();

  controller.replaceState({ volume: "0.6", muted: "true" });
  controller.applyOutput();
  controller.render();

  assert.deepEqual(controller.getState(), {
    volume: 0.6,
    muted: true,
    lastAudibleVolume: 0.6,
  });
  assert.deepEqual(applied.at(-1), {
    volume: 0.6,
    outputVolume: 0,
    muted: true,
  });
  assert.deepEqual(rendered.at(-1), {
    volume: 0.6,
    muted: true,
    lastAudibleVolume: 0.6,
  });
  assert.deepEqual(persisted, []);
});
