import assert from "node:assert/strict";
import test from "node:test";

import {
  createPlayerTrackController,
  PlayerTrackController,
} from "../player/player_track_controller.js";

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
  const errors = [];

  const controller = createPlayerTrackController({
    refreshAudioTracks() {
      calls.push(["refreshAudioTracks"]);
      return ["audio"];
    },
    refreshSubtitleTracks() {
      calls.push(["refreshSubtitleTracks"]);
      return ["subtitle"];
    },
    selectAudioTrack(trackIndex) {
      calls.push(["selectAudioTrack", trackIndex]);
      return trackIndex;
    },
    selectSubtitleTrack(trackIndex) {
      calls.push(["selectSubtitleTrack", trackIndex]);
      return trackIndex;
    },
    setSubtitleOffset(offsetMs) {
      calls.push(["setSubtitleOffset", offsetMs]);
      return offsetMs;
    },
    loadExternalSubtitle(...args) {
      calls.push(["loadExternalSubtitle", ...args]);
      return args.at(-1);
    },
    loadNativeExternalSubtitle(...args) {
      calls.push(["loadNativeExternalSubtitle", ...args]);
      return args.at(-1);
    },
    reloadNativeExternalSubtitle(...args) {
      calls.push(["reloadNativeExternalSubtitle", ...args]);
      return "reloaded";
    },
    onError(operation, error) {
      errors.push([operation, error]);
    },
    ...overrides,
  });

  return { calls, controller, errors };
}

test("validates every required track operation boundary", () => {
  assert.throws(() => new PlayerTrackController({}), /requires refreshAudioTracks\(\)/);

  assert.throws(
    () =>
      new PlayerTrackController({
        refreshAudioTracks() {},
        refreshSubtitleTracks() {},
        selectAudioTrack() {},
        selectSubtitleTrack() {},
        setSubtitleOffset() {},
        loadExternalSubtitle() {},
        loadNativeExternalSubtitle() {},
        reloadNativeExternalSubtitle() {},
        onError: true,
      }),
    /onError must be a function/,
  );
});

test("routes refresh and selection operations through one lifecycle boundary", () => {
  const { calls, controller } = createHarness();

  assert.deepEqual(controller.refreshAudioTracks(), ["audio"]);
  assert.deepEqual(controller.refreshSubtitleTracks(), ["subtitle"]);
  assert.equal(controller.selectAudioTrack(2), 2);
  assert.equal(controller.selectSubtitleTrack(-1), -1);
  assert.equal(controller.setSubtitleOffset("250"), 250);
  assert.equal(controller.loadExternalSubtitle("avplayer", "subtitle.vtt"), "subtitle.vtt");
  assert.equal(controller.loadNativeExternalSubtitle(17, "subtitle.vtt"), "subtitle.vtt");
  assert.equal(controller.reloadNativeExternalSubtitle("subtitle-pt"), "reloaded");

  assert.deepEqual(calls, [
    ["refreshAudioTracks"],
    ["refreshSubtitleTracks"],
    ["selectAudioTrack", 2],
    ["selectSubtitleTrack", -1],
    ["setSubtitleOffset", 250],
    ["loadExternalSubtitle", "avplayer", "subtitle.vtt"],
    ["loadNativeExternalSubtitle", 17, "subtitle.vtt"],
    ["reloadNativeExternalSubtitle", "subtitle-pt"],
  ]);

  assert.deepEqual(controller.snapshot().applied, {
    audioTrack: 2,
    subtitleTrack: -1,
    subtitleOffset: 250,
  });
});

test("normalizes invalid subtitle offsets without changing track identifiers", () => {
  const { calls, controller } = createHarness();

  controller.selectAudioTrack("audio-pt");
  controller.selectSubtitleTrack("subtitle-pt-br");
  controller.setSubtitleOffset(Number.NaN);

  assert.deepEqual(calls, [
    ["selectAudioTrack", "audio-pt"],
    ["selectSubtitleTrack", "subtitle-pt-br"],
    ["setSubtitleOffset", 0],
  ]);
});

test("deduplicates the same in-flight selection", async () => {
  const pending = deferred();
  let invocationCount = 0;
  const { controller } = createHarness({
    selectAudioTrack() {
      invocationCount += 1;
      return pending.promise;
    },
  });

  const first = controller.selectAudioTrack(3);
  const second = controller.selectAudioTrack(3);

  assert.equal(first, second);
  assert.equal(invocationCount, 1);
  assert.equal(controller.snapshot().pending.audioTrack, true);

  pending.resolve("selected");
  assert.equal(await first, "selected");
  assert.equal(controller.snapshot().pending.audioTrack, false);
  assert.equal(controller.snapshot().applied.audioTrack, 3);
});

test("unrelated operations do not invalidate each other's completion", async () => {
  const audio = deferred();
  const subtitles = deferred();
  const { controller } = createHarness({
    selectAudioTrack() {
      return audio.promise;
    },
    selectSubtitleTrack() {
      return subtitles.promise;
    },
  });

  const audioSelection = controller.selectAudioTrack(4);
  const subtitleSelection = controller.selectSubtitleTrack(2);

  audio.resolve("audio-selected");
  subtitles.resolve("subtitle-selected");

  assert.equal(await audioSelection, "audio-selected");
  assert.equal(await subtitleSelection, "subtitle-selected");
  assert.equal(controller.snapshot().applied.audioTrack, 4);
  assert.equal(controller.snapshot().applied.subtitleTrack, 2);
});

test("a stale completion cannot overwrite the latest desired selection", async () => {
  const first = deferred();
  const second = deferred();
  const { controller } = createHarness({
    selectSubtitleTrack(trackIndex) {
      return trackIndex === 1 ? first.promise : second.promise;
    },
  });

  const firstSelection = controller.selectSubtitleTrack(1);
  const secondSelection = controller.selectSubtitleTrack(2);

  first.resolve("old");
  assert.equal(await firstSelection, "old");
  assert.equal(controller.snapshot().applied.subtitleTrack, null);

  second.resolve("new");
  assert.equal(await secondSelection, "new");
  assert.equal(controller.snapshot().desired.subtitleTrack, 2);
  assert.equal(controller.snapshot().applied.subtitleTrack, 2);
});

test("deduplicates identical external subtitle loads while pending", async () => {
  const pending = deferred();
  let invocationCount = 0;
  const avPlayer = {};
  const { controller } = createHarness({
    loadExternalSubtitle(receivedPlayer) {
      assert.equal(receivedPlayer, avPlayer);
      invocationCount += 1;
      return pending.promise;
    },
  });

  const first = controller.loadExternalSubtitle(avPlayer);
  const second = controller.loadExternalSubtitle(avPlayer);

  assert.equal(first, second);
  assert.equal(invocationCount, 1);
  assert.equal(controller.snapshot().pending.loadExternalSubtitle, true);

  pending.resolve("loaded");
  assert.equal(await first, "loaded");
  assert.equal(controller.snapshot().pending.loadExternalSubtitle, false);
});

test("reports synchronous and asynchronous failures while preserving them", async () => {
  const syncError = new Error("sync failed");
  const asyncError = new Error("async failed");
  const { controller, errors } = createHarness({
    selectAudioTrack() {
      throw syncError;
    },
    selectSubtitleTrack() {
      return Promise.reject(asyncError);
    },
  });

  assert.throws(() => controller.selectAudioTrack(1), syncError);
  await assert.rejects(controller.selectSubtitleTrack(1), asyncError);

  assert.deepEqual(errors, [
    ["audio_track", syncError],
    ["subtitle_track", asyncError],
  ]);
});

test("diagnostic failures cannot replace the original operation error", () => {
  const operationError = new Error("selection failed");
  const controller = createPlayerTrackController({
    refreshAudioTracks() {},
    refreshSubtitleTracks() {},
    selectAudioTrack() {
      throw operationError;
    },
    selectSubtitleTrack() {},
    setSubtitleOffset() {},
    loadExternalSubtitle() {},
    loadNativeExternalSubtitle() {},
    reloadNativeExternalSubtitle() {},
    onError() {
      throw new Error("logger failed");
    },
  });

  assert.throws(() => controller.selectAudioTrack(1), operationError);
});

test("destroy is idempotent and blocks later track mutations", async () => {
  const pending = deferred();
  const { calls, controller } = createHarness({
    selectAudioTrack() {
      calls.push(["selectAudioTrack", 4]);
      return pending.promise;
    },
  });

  const selection = controller.selectAudioTrack(4);
  assert.equal(controller.destroy(), true);
  assert.equal(controller.destroy(), false);
  assert.equal(controller.destroyed, true);
  assert.equal(controller.selectSubtitleTrack(2), undefined);
  assert.equal(controller.refreshAudioTracks(), undefined);

  pending.resolve("late");
  assert.equal(await selection, "late");
  assert.equal(controller.snapshot().applied.audioTrack, null);
});
