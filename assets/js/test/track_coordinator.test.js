import assert from "node:assert/strict";
import test from "node:test";

import { createTrackCoordinator } from "../player/track_coordinator.js";

function engineDouble(overrides = {}) {
  return {
    load() {},
    play() {},
    pause() {},
    seek() {},
    destroy() {},
    ...overrides,
  };
}

test("normalizes heterogeneous audio and subtitle tracks", () => {
  const engine = engineDouble({
    getAudioTracks() {
      return [{ id: "pt", name: "Português", lang: "pt-BR", selected: true }];
    },
    getSubtitleTracks() {
      return [{ index: 2, title: "English CC", languageCode: "en", forced: true }];
    },
  });
  const coordinator = createTrackCoordinator({ getEngine: () => engine });

  assert.deepEqual(coordinator.audioTracks()[0], {
    id: "pt",
    index: 0,
    kind: "audio",
    label: "Português",
    language: "pt-BR",
    active: true,
    default: false,
    forced: false,
    raw: { id: "pt", name: "Português", lang: "pt-BR", selected: true },
  });
  assert.equal(coordinator.subtitleTracks()[0].id, 2);
  assert.equal(coordinator.subtitleTracks()[0].forced, true);
});

test("selects tracks through optional engine capabilities", () => {
  const calls = [];
  const changes = [];
  const engine = engineDouble({
    selectAudioTrack(id) {
      calls.push(["audio", id]);
      return true;
    },
    selectSubtitleTrack(id) {
      calls.push(["subtitle", id]);
      return { selected: id };
    },
  });
  const coordinator = createTrackCoordinator({
    getEngine: () => engine,
    onChange: (change) => changes.push(change),
  });

  assert.equal(coordinator.selectAudioTrack("pt"), true);
  assert.deepEqual(coordinator.selectSubtitleTrack(4), { selected: 4 });
  assert.deepEqual(calls, [
    ["audio", "pt"],
    ["subtitle", 4],
  ]);
  assert.equal(changes.length, 2);
});

test("degrades safely when an engine lacks track features", () => {
  const coordinator = createTrackCoordinator({ getEngine: () => engineDouble() });

  assert.deepEqual(coordinator.audioTracks(), []);
  assert.deepEqual(coordinator.subtitleTracks(), []);
  assert.equal(coordinator.selectAudioTrack(1), false);
  assert.equal(coordinator.selectSubtitleTrack(1), false);
  assert.equal(coordinator.loadExternalSubtitle({ url: "subtitle.vtt" }), false);
  assert.equal(coordinator.setSubtitleDelay(Number.NaN), false);
});

test("contains engine failures and reports diagnostics", () => {
  const errors = [];
  const coordinator = createTrackCoordinator({
    getEngine: () =>
      engineDouble({
        getAudioTracks() {
          throw new Error("broken tracks");
        },
      }),
    onError: (error, method) => errors.push([error.message, method]),
  });

  assert.deepEqual(coordinator.audioTracks(), []);
  assert.deepEqual(errors, [["broken tracks", "getAudioTracks"]]);
});

test("publishes an immutable capability and track snapshot", () => {
  const coordinator = createTrackCoordinator({
    getEngine: () =>
      engineDouble({
        getAudioTracks: () => [{ id: 1 }],
        getSubtitleTracks: () => [{ id: 2 }],
      }),
  });

  const snapshot = coordinator.snapshot();
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.audioTracks), true);
  assert.equal(snapshot.capabilities.getAudioTracks, true);
  assert.equal(snapshot.capabilities.selectAudioTrack, false);
});
