import assert from "node:assert/strict";
import test from "node:test";

import {
  createPlayerTrackPresentationController,
  PlayerTrackPresentationController,
} from "../player/player_track_presentation_controller.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function createHarness(overrides = {}) {
  const calls = [];
  const emitted = [];
  const errors = [];
  const states = [];
  let currentSession = overrides.currentSession ?? 7;

  const controller = createPlayerTrackPresentationController({
    emit(event, payload) {
      emitted.push([event, payload]);
      return overrides.emit?.(event, payload);
    },
    getContentId() {
      return overrides.contentId ?? "movie-42";
    },
    isSessionCurrent(sessionId) {
      return overrides.isSessionCurrent
        ? overrides.isSessionCurrent(sessionId)
        : sessionId === currentSession;
    },
    onError(operation, error) {
      errors.push([operation, error]);
      overrides.onError?.(operation, error);
    },
    onStateChange(snapshot) {
      states.push(snapshot);
      overrides.onStateChange?.(snapshot);
    },
    renderAudioOptions(tracks, selectedTrack, selectTrack) {
      calls.push(["renderAudioOptions", tracks, selectedTrack, selectTrack]);
      return overrides.renderAudioOptions?.(tracks, selectedTrack, selectTrack);
    },
    renderSubtitleOptions(tracks, selectedTrack, selectTrack) {
      calls.push(["renderSubtitleOptions", tracks, selectedTrack, selectTrack]);
      return overrides.renderSubtitleOptions?.(tracks, selectedTrack, selectTrack);
    },
    renderSubtitleOffset(label, offsetMs) {
      calls.push(["renderSubtitleOffset", label, offsetMs]);
      return overrides.renderSubtitleOffset?.(label, offsetMs);
    },
    saveAudioPreference(trackIndex, contentId) {
      calls.push(["saveAudioPreference", trackIndex, contentId]);
      return overrides.saveAudioPreference?.(trackIndex, contentId);
    },
    saveSubtitlePreference(trackIndex, contentId) {
      calls.push(["saveSubtitlePreference", trackIndex, contentId]);
      return overrides.saveSubtitlePreference?.(trackIndex, contentId);
    },
    initialState: overrides.initialState,
  });

  return {
    calls,
    controller,
    emitted,
    errors,
    setCurrentSession(sessionId) {
      currentSession = sessionId;
    },
    states,
  };
}

const audioTracks = Object.freeze([
  Object.freeze({ index: 0, language: "en", label: "English" }),
  Object.freeze({ index: 1, language: "pt-BR", label: "Português" }),
]);

const subtitleTracks = Object.freeze([
  Object.freeze({ index: 0, language: "en", label: "English" }),
  Object.freeze({ index: 1, language: "pt-BR", label: "Português" }),
]);

test("validates every presentation boundary", () => {
  assert.throws(() => new PlayerTrackPresentationController(), /requires emit\(\)/);
  assert.throws(
    () =>
      new PlayerTrackPresentationController({
        emit() {},
        getContentId() {},
        renderAudioOptions() {},
        renderSubtitleOptions() {},
        renderSubtitleOffset() {},
        saveAudioPreference() {},
        saveSubtitlePreference: true,
      }),
    /requires saveSubtitlePreference\(\)/,
  );
});

test("hydrates one immutable bounded presentation snapshot", () => {
  const { controller } = createHarness({
    initialState: {
      audioTracks,
      selectedAudioTrack: 1,
      selectedSubtitleTrack: 0,
      subtitleOffsetMs: 900_000,
      subtitleTracks,
    },
  });

  const snapshot = controller.snapshot();
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.audioTracks), true);
  assert.equal(Object.isFrozen(snapshot.subtitleTracks), true);
  assert.equal(snapshot.selectedAudioTrack, 1);
  assert.equal(snapshot.selectedSubtitleTrack, 0);
  assert.equal(snapshot.subtitleOffsetMs, 600_000);
});

test("applies the preferred audio command before rendering and announcing tracks", async () => {
  const harness = createHarness();
  const selected = [];

  const result = await harness.controller.presentAudioTracks({
    activeTrack: 0,
    preferredTrack: 1,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: async (trackIndex) => {
      selected.push(trackIndex);
      return harness.controller.presentAudioSelection(trackIndex, { sessionId: 7 });
    },
  });

  assert.deepEqual(selected, [1]);
  assert.equal(result.length, 2);
  assert.equal(harness.controller.snapshot().selectedAudioTrack, 1);
  assert.deepEqual(harness.calls[0], ["saveAudioPreference", 1, "movie-42"]);
  assert.equal(harness.calls[1][0], "renderAudioOptions");
  assert.equal(harness.calls[1][2], 1);
  assert.equal(harness.emitted[0][0], "audio_track_changed");
  assert.equal(harness.emitted[0][1].label, "Português Português (BR)");
  assert.equal(harness.emitted[1][0], "audio_tracks_available");
});

test("uses the Portuguese audio preference when no saved selection is valid", async () => {
  const harness = createHarness();
  const selected = [];

  await harness.controller.presentAudioTracks({
    activeTrack: 0,
    preferredTrack: 99,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: async (trackIndex) => {
      selected.push(trackIndex);
      return harness.controller.presentAudioSelection(trackIndex, { sessionId: 7 });
    },
  });

  assert.deepEqual(selected, [1]);
});

test("normalizes and presents probed metadata without owning engine commands", () => {
  const harness = createHarness();
  const onAudioSelect = () => {};
  const onSubtitleSelect = () => {};

  const result = harness.controller.presentProbedTracks({
    audioTracks: [
      { channels: 2, codec: "aac", index: 1, language: "eng", title: "English" },
      { channels: 6, codec: "eac3", index: 4, language: "pt-BR", title: "Português" },
    ],
    onAudioSelect,
    onSubtitleSelect,
    sessionId: 7,
    subtitleTracks: [{ codec: "subrip", index: 7, language: "pt-BR", title: "Português" }],
  });

  assert.equal(Object.isFrozen(result), true);
  assert.equal(Object.isFrozen(result.audioTracks), true);
  assert.equal(Object.isFrozen(result.subtitleTracks), true);
  assert.equal(result.selectedAudioTrack, 1);
  assert.equal(result.selectedSubtitleTrack, -1);
  assert.deepEqual(result.audioTracks[1], {
    id: 4,
    index: 1,
    label: "Português Português (BR) (eac3) 6ch",
    language: "pt-BR",
  });
  assert.deepEqual(result.subtitleTracks[0], {
    id: 7,
    index: 0,
    label: "Português Português (BR) (subrip)",
    language: "pt-BR",
  });
  assert.deepEqual(harness.calls[0], ["renderAudioOptions", result.audioTracks, 1, onAudioSelect]);
  assert.deepEqual(harness.calls[1], [
    "renderSubtitleOptions",
    result.subtitleTracks,
    -1,
    onSubtitleSelect,
  ]);
  assert.equal(harness.emitted[0][0], "audio_tracks_available");
  assert.equal(harness.emitted[1][0], "subtitle_tracks_available");
  assert.equal(
    harness.calls.some(([operation]) => operation.startsWith("save")),
    false,
  );
});

test("suppresses unavailable and stale probed metadata presentation", () => {
  const harness = createHarness();

  const empty = harness.controller.presentProbedTracks({
    audioTracks: [{ index: 1, language: "en" }],
    sessionId: 7,
    subtitleTracks: [],
  });
  assert.deepEqual(empty.audioTracks, []);
  assert.deepEqual(empty.subtitleTracks, []);
  assert.equal(harness.calls.length, 0);
  assert.equal(harness.emitted.length, 0);

  harness.setCurrentSession(8);
  assert.equal(
    harness.controller.presentProbedTracks({
      audioTracks,
      sessionId: 7,
      subtitleTracks,
    }),
    false,
  );
  assert.equal(harness.calls.length, 0);
  assert.equal(harness.emitted.length, 0);
});

test("renders empty audio capabilities without persisting a selection", async () => {
  const harness = createHarness();

  const result = await harness.controller.presentAudioTracks({
    sessionId: 7,
    tracks: [],
    selectTrack() {
      throw new Error("must not select an empty track list");
    },
  });

  assert.deepEqual(result, []);
  assert.equal(harness.calls[0][0], "renderAudioOptions");
  assert.equal(harness.emitted.length, 0);
});

test("applies subtitle preference, renders disabled option metadata, and persists selection", async () => {
  const harness = createHarness();
  const selected = [];

  await harness.controller.presentSubtitleTracks({
    activeTrack: -1,
    preferredTrack: 1,
    sessionId: 7,
    subtitlesEnabled: true,
    tracks: subtitleTracks,
    selectTrack: async (trackIndex) => {
      selected.push(trackIndex);
      return harness.controller.presentSubtitleSelection(trackIndex, { sessionId: 7 });
    },
  });

  assert.deepEqual(selected, [1]);
  assert.equal(harness.controller.snapshot().selectedSubtitleTrack, 1);
  assert.deepEqual(harness.calls[0], ["saveSubtitlePreference", 1, "movie-42"]);
  assert.equal(harness.calls[1][0], "renderSubtitleOptions");
  assert.equal(harness.emitted[0][0], "subtitle_track_changed");
  assert.equal(harness.emitted[1][0], "subtitle_tracks_available");
  assert.deepEqual(harness.emitted[1][1].tracks[0], {
    index: -1,
    label: "Desativado",
  });
});

test("keeps subtitles disabled when product preference or policy disables them", async () => {
  const harness = createHarness();
  const selected = [];

  await harness.controller.presentSubtitleTracks({
    activeTrack: 1,
    preferredTrack: 1,
    sessionId: 7,
    subtitlesEnabled: false,
    tracks: subtitleTracks,
    selectTrack: async (trackIndex) => {
      selected.push(trackIndex);
      return harness.controller.presentSubtitleSelection(trackIndex, { sessionId: 7 });
    },
  });

  assert.deepEqual(selected, [-1]);
  assert.equal(harness.emitted[0][1].label, "Desativado");
});

test("normalizes and renders the subtitle offset label", () => {
  const harness = createHarness();

  assert.equal(harness.controller.presentSubtitleOffset(1_250, { sessionId: 7 }), 1_250);
  assert.deepEqual(harness.calls[0], ["renderSubtitleOffset", "+1.3s", 1_250]);
  assert.equal(harness.controller.presentSubtitleOffset(-900_000, { sessionId: 7 }), -600_000);
  assert.deepEqual(harness.calls[1], ["renderSubtitleOffset", "-600.0s", -600_000]);
  assert.equal(harness.controller.presentSubtitleOffset("invalid", { sessionId: 7 }), false);
});

test("presents a normalized native subtitle snapshot through the public selection command", async () => {
  const harness = createHarness();
  const selected = [];
  const nativeSnapshot = Object.freeze({
    tracks: Object.freeze([
      Object.freeze({
        id: "external-pt",
        index: 0,
        label: "Português (auto)",
        language: "pt-BR",
        selectionId: "external-pt",
      }),
    ]),
  });

  const result = await harness.controller.presentNativeSubtitleSnapshot(nativeSnapshot, {
    selectedTrack: 0,
    sessionId: 7,
    selectTrack: async (trackIndex) => {
      selected.push(trackIndex);
      return harness.controller.presentSubtitleSelection(trackIndex, { sessionId: 7 });
    },
  });

  assert.strictEqual(result, nativeSnapshot);
  assert.deepEqual(selected, [0]);
  assert.equal(harness.controller.snapshot().subtitleTracks[0].label, "Português (auto)");
  assert.equal(harness.calls[1][0], "renderSubtitleOptions");
  assert.equal(harness.emitted[1][0], "subtitle_tracks_available");
});

test("clears native subtitle presentation without mutating engine ownership", () => {
  const harness = createHarness({
    initialState: {
      selectedSubtitleTrack: 0,
      subtitleTracks,
    },
  });
  const selectTrack = () => true;

  assert.equal(harness.controller.clearSubtitlePresentation({ sessionId: 7, selectTrack }), true);
  assert.deepEqual(harness.controller.snapshot().subtitleTracks, []);
  assert.equal(harness.controller.snapshot().selectedSubtitleTrack, -1);
  assert.deepEqual(harness.calls[0], ["renderSubtitleOptions", [], -1, selectTrack]);
  assert.equal(harness.emitted.length, 0);
});

test("a stale session cannot persist, render, or announce presentation state", async () => {
  const selection = deferred();
  const harness = createHarness();

  const resultPromise = harness.controller.presentAudioTracks({
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: () => selection.promise,
  });
  harness.setCurrentSession(8);
  selection.resolve(1);

  assert.equal(await resultPromise, false);
  assert.equal(harness.calls.length, 0);
  assert.equal(harness.emitted.length, 0);
  assert.equal(harness.controller.presentAudioSelection(0, { sessionId: 7 }), false);
});

test("clearing subtitles invalidates an older pending subtitle refresh", async () => {
  const selection = deferred();
  const harness = createHarness();
  const selectTrack = () => selection.promise;

  const pending = harness.controller.presentSubtitleTracks({
    preferredTrack: 0,
    sessionId: 7,
    subtitlesEnabled: true,
    tracks: subtitleTracks,
    selectTrack,
  });

  assert.equal(harness.controller.clearSubtitlePresentation({ sessionId: 7, selectTrack }), true);
  selection.resolve(0);

  assert.equal(await pending, false);
  assert.equal(
    harness.calls.filter(([operation]) => operation === "renderSubtitleOptions").length,
    1,
  );
  assert.deepEqual(harness.controller.snapshot().subtitleTracks, []);
  assert.equal(harness.controller.snapshot().selectedSubtitleTrack, -1);
  assert.equal(harness.emitted.length, 0);
});

test("new probed metadata invalidates older pending engine track presentation", async () => {
  const selection = deferred();
  const harness = createHarness();

  const pending = harness.controller.presentAudioTracks({
    preferredTrack: 0,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: () => selection.promise,
  });
  const probe = harness.controller.presentProbedTracks({
    audioTracks: [
      { channels: 2, codec: "aac", index: 1, language: "en", title: "English" },
      { channels: 2, codec: "aac", index: 2, language: "pt-BR", title: "Português" },
    ],
    sessionId: 7,
    subtitleTracks: [],
  });

  assert.equal(probe.selectedAudioTrack, 1);
  selection.resolve(0);
  assert.equal(await pending, false);
  assert.equal(harness.calls.filter(([operation]) => operation === "renderAudioOptions").length, 1);
  assert.equal(harness.emitted.length, 1);
  assert.equal(harness.emitted[0][0], "audio_tracks_available");
});

test("a newer track refresh suppresses the older asynchronous presentation", async () => {
  const firstSelection = deferred();
  const harness = createHarness();

  const firstResult = harness.controller.presentAudioTracks({
    preferredTrack: 0,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: () => firstSelection.promise,
  });
  const secondResult = harness.controller.presentAudioTracks({
    preferredTrack: 1,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: (trackIndex) =>
      harness.controller.presentAudioSelection(trackIndex, { sessionId: 7 }),
  });

  assert.deepEqual(await secondResult, audioTracks);
  firstSelection.resolve(0);
  assert.equal(await firstResult, false);
  assert.equal(harness.calls.filter(([operation]) => operation === "renderAudioOptions").length, 1);
  assert.equal(harness.controller.snapshot().selectedAudioTrack, 1);
});

test("rendering, persistence, and diagnostic failures remain non-fatal", async () => {
  const harness = createHarness({
    emit() {
      throw new Error("emit failed");
    },
    onError() {
      throw new Error("diagnostic failed");
    },
    renderAudioOptions() {
      throw new Error("render failed");
    },
    saveAudioPreference() {
      throw new Error("storage failed");
    },
  });

  const result = await harness.controller.presentAudioTracks({
    preferredTrack: 0,
    sessionId: 7,
    tracks: audioTracks,
    selectTrack: (trackIndex) =>
      harness.controller.presentAudioSelection(trackIndex, { sessionId: 7 }),
  });

  assert.equal(result.length, 2);
  assert.equal(harness.controller.snapshot().selectedAudioTrack, 0);
});

test("destroy is idempotent and terminal", async () => {
  const harness = createHarness();

  assert.equal(harness.controller.destroy(), true);
  assert.equal(harness.controller.destroy(), false);
  assert.equal(harness.controller.destroyed, true);
  assert.equal(
    await harness.controller.presentAudioTracks({ sessionId: 7, tracks: audioTracks }),
    false,
  );
  assert.equal(harness.controller.presentSubtitleOffset(0, { sessionId: 7 }), false);
});
