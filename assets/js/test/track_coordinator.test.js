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

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

test("refreshes and caches normalized asynchronous engine tracks", async () => {
  const audioRaw = { id: 11, name: "Português", lang: "pt-BR", selected: true };
  const subtitleRaw = { index: 2, title: "English CC", languageCode: "en", forced: true };
  const engine = engineDouble({
    async getAudioTracks() {
      return [audioRaw];
    },
    getSubtitleTracks() {
      return [subtitleRaw];
    },
  });
  const coordinator = createTrackCoordinator({ getEngine: () => engine });

  assert.deepEqual(coordinator.audioTracks(), []);

  const audio = await coordinator.refreshAudioTracks();
  const subtitles = coordinator.refreshSubtitleTracks();

  assert.deepEqual(audio[0], {
    id: 11,
    index: 0,
    kind: "audio",
    label: "Português",
    language: "pt-BR",
    active: true,
    default: false,
    forced: false,
    raw: audioRaw,
  });
  assert.equal(subtitles[0].id, 2);
  assert.equal(subtitles[0].forced, true);
  assert.equal(coordinator.audioTracks(), audio);
  assert.equal(coordinator.subtitleTracks(), subtitles);

  const snapshot = coordinator.snapshot();
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.audioTracks), true);
  assert.equal(snapshot.audioTracks, audio);
  assert.equal(snapshot.capabilities.getAudioTracks, true);
});

test("maps product indexes to concrete engine track identifiers", async () => {
  const calls = [];
  const changes = [];
  const engine = engineDouble({
    getAudioTracks() {
      return [{ id: 71, index: 0, label: "Português" }];
    },
    getSubtitleTracks() {
      return [{ id: "subtitle-pt", index: 0, label: "Português" }];
    },
    async selectAudioTrack(id) {
      calls.push(["audio", id]);
      return id;
    },
    async selectSubtitleTrack(id) {
      calls.push(["subtitle", id]);
      return id;
    },
  });
  const coordinator = createTrackCoordinator({
    getEngine: () => engine,
    onChange: (change) => changes.push(change),
  });

  await coordinator.refreshAudioTracks();
  await coordinator.refreshSubtitleTracks();

  assert.equal(await coordinator.selectAudioTrack(0), 71);
  assert.equal(await coordinator.selectSubtitleTrack(0), "subtitle-pt");
  assert.equal(await coordinator.selectSubtitleTrack(-1), -1);
  assert.deepEqual(calls, [
    ["audio", 71],
    ["subtitle", "subtitle-pt"],
    ["subtitle", -1],
  ]);
  assert.equal(changes.length, 3);
  assert.equal(changes[0].trackId, 0);
  assert.equal(changes[0].selectionId, 71);
  assert.equal(coordinator.audioTracks()[0].active, true);
  assert.equal(coordinator.subtitleTracks()[0].active, false);
});

test("uses an engine-provided selection id instead of display metadata", async () => {
  const calls = [];
  const engine = engineDouble({
    getAudioTracks: () => [{ id: "display-pt", index: 1, selectionId: 1 }],
    selectAudioTrack(id) {
      calls.push(id);
      return id;
    },
  });
  const coordinator = createTrackCoordinator({ getEngine: () => engine });

  coordinator.refreshAudioTracks();

  assert.equal(coordinator.selectAudioTrack(1), 1);
  assert.deepEqual(calls, [1]);
});

test("drops stale asynchronous discovery after the active engine changes", async () => {
  const firstRefresh = deferred();
  const first = engineDouble({ getAudioTracks: () => firstRefresh.promise });
  const second = engineDouble({ getAudioTracks: () => [{ id: "current" }] });
  let active = first;
  const coordinator = createTrackCoordinator({ getEngine: () => active });

  const stale = coordinator.refreshAudioTracks();
  active = second;
  const current = coordinator.refreshAudioTracks();
  firstRefresh.resolve([{ id: "stale" }]);

  assert.equal(current[0].id, "current");
  assert.deepEqual(await stale, current);
  assert.equal(coordinator.audioTracks()[0].id, "current");
});

test("invalidates cached tracks when the active engine changes", () => {
  const first = engineDouble({ getAudioTracks: () => [{ id: 1 }] });
  const second = engineDouble({ getAudioTracks: () => [{ id: 2 }] });
  let active = first;
  const coordinator = createTrackCoordinator({ getEngine: () => active });

  coordinator.refreshAudioTracks();
  assert.equal(coordinator.audioTracks()[0].id, 1);

  active = second;
  assert.deepEqual(coordinator.audioTracks(), []);
  coordinator.refreshAudioTracks();
  assert.equal(coordinator.audioTracks()[0].id, 2);
});

test("ignores stale asynchronous selection completions", async () => {
  let resolveEnglish;
  let resolvePortuguese;
  const changes = [];
  const engine = engineDouble({
    getAudioTracks: () => [
      { id: "en", selectionId: 11, name: "English" },
      { id: "pt", selectionId: 22, name: "Português" },
    ],
    selectAudioTrack(selectionId) {
      return new Promise((resolve) => {
        if (selectionId === 11) resolveEnglish = () => resolve(selectionId);
        if (selectionId === 22) resolvePortuguese = () => resolve(selectionId);
      });
    },
  });
  const coordinator = createTrackCoordinator({
    getEngine: () => engine,
    onChange: (change) => changes.push(change),
  });

  await coordinator.refreshAudioTracks();
  const english = coordinator.selectAudioTrack(0);
  const portuguese = coordinator.selectAudioTrack(1);

  resolvePortuguese();
  assert.equal(await portuguese, 22);
  resolveEnglish();
  assert.equal(await english, 11);

  assert.deepEqual(
    coordinator.audioTracks().map((track) => track.active),
    [false, true],
  );
  assert.deepEqual(
    changes.map(({ trackId, selectionId }) => [trackId, selectionId]),
    [[1, 22]],
  );
});

test("invalidates a pending selection when the active engine changes", async () => {
  let resolveOldSelection;
  let activeEngine;
  const changes = [];
  const oldEngine = engineDouble({
    getAudioTracks: () => [{ id: "old", selectionId: 7 }],
    selectAudioTrack() {
      return new Promise((resolve) => {
        resolveOldSelection = () => resolve(7);
      });
    },
  });
  const newEngine = engineDouble({
    getAudioTracks: () => [
      { id: "new-en", selectionId: 8 },
      { id: "new-pt", selectionId: 9 },
    ],
  });
  activeEngine = oldEngine;
  const coordinator = createTrackCoordinator({
    getEngine: () => activeEngine,
    onChange: (change) => changes.push(change),
  });

  await coordinator.refreshAudioTracks();
  const pending = coordinator.selectAudioTrack(0);
  activeEngine = newEngine;
  await coordinator.refreshAudioTracks();
  resolveOldSelection();
  assert.equal(await pending, 7);

  assert.deepEqual(
    coordinator.audioTracks().map((track) => track.active),
    [false, false],
  );
  assert.deepEqual(changes, []);
});

test("degrades safely when an engine lacks track features", () => {
  const coordinator = createTrackCoordinator({ getEngine: () => engineDouble() });

  assert.deepEqual(coordinator.refreshAudioTracks(), []);
  assert.deepEqual(coordinator.refreshSubtitleTracks(), []);
  assert.equal(coordinator.selectAudioTrack(1), false);
  assert.equal(coordinator.selectSubtitleTrack(1), false);
  assert.equal(coordinator.loadExternalSubtitle({ url: "subtitle.vtt" }), false);
  assert.equal(coordinator.setSubtitleDelay(Number.NaN), false);
});

test("contains discovery failures and reports diagnostics", async () => {
  const errors = [];
  const coordinator = createTrackCoordinator({
    getEngine: () =>
      engineDouble({
        getAudioTracks() {
          throw new Error("broken audio tracks");
        },
        async getSubtitleTracks() {
          throw new Error("broken subtitle tracks");
        },
      }),
    onError: (error, method) => errors.push([error.message, method]),
  });

  assert.deepEqual(coordinator.refreshAudioTracks(), []);
  assert.deepEqual(await coordinator.refreshSubtitleTracks(), []);
  assert.deepEqual(errors, [
    ["broken audio tracks", "getAudioTracks"],
    ["broken subtitle tracks", "getSubtitleTracks"],
  ]);
});

test("reports asynchronous command failures without replacing them", async () => {
  const errors = [];
  const failure = new Error("track switch failed");
  const coordinator = createTrackCoordinator({
    getEngine: () =>
      engineDouble({
        async selectAudioTrack() {
          throw failure;
        },
      }),
    onError: (error, method) => errors.push([error, method]),
  });

  await assert.rejects(coordinator.selectAudioTrack(0), (error) => error === failure);
  assert.deepEqual(errors, [[failure, "selectAudioTrack"]]);
});
