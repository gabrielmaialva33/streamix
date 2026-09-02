import assert from "node:assert/strict";
import test from "node:test";

import {
  createTrackProbeController,
  TRACK_PROBE_AUTO_SWITCH_DELAY_MS,
  TRACK_PROBE_HOST_METHODS,
} from "../player/track_probe_controller.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createHarness({ state: stateOverrides = {}, response, presentation } = {}) {
  const calls = {
    fetches: [],
    presented: [],
    audioSelections: [],
    subtitleSelections: [],
    switches: [],
    timeouts: [],
  };
  const state = {
    avPlayer: false,
    contentId: "42",
    contentType: "movie",
    destroyed: false,
    policy: { shouldProbeTracks: true, avoidSpeculativeWork: false, reason: "ok" },
    prefersAVPlayer: false,
    sessionId: 3,
    switching: false,
    usingAVPlayer: false,
    video: { currentTime: 17.4, paused: false },
    audioTracks: [{ id: 0 }, { id: 1 }],
    subtitleTracks: [{ id: 0 }],
    ...stateOverrides,
  };
  const host = {
    getContentId: () => state.contentId,
    getContentType: () => state.contentType,
    getResourcePolicy: () => state.policy,
    getSessionId: () => state.sessionId,
    getVideo: () => state.video,
    hasAVPlayer: () => state.avPlayer,
    isDestroyed: () => state.destroyed,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    isSwitchingToAVPlayer: () => state.switching,
    isUsingAVPlayer: () => state.usingAVPlayer,
    prefersAVPlayer: () => state.prefersAVPlayer,
    presentProbedTracks: (options) => {
      calls.presented.push(options);
      return (
        presentation ?? {
          audioTracks: options.audioTracks,
          subtitleTracks: options.subtitleTracks,
          selectedAudioTrack: 1,
        }
      );
    },
    setAudioTrack: (index) => calls.audioSelections.push(index),
    setSubtitleTrack: (index) => calls.subtitleSelections.push(index),
    switchToAVPlayerWithTrack: (...args) => {
      calls.switches.push(args);
      return true;
    },
    updateAudioTracks: async () => state.audioTracks,
    updateSubtitleTracks: async () => state.subtitleTracks,
  };
  const controller = createTrackProbeController({
    host,
    logger: silentLogger,
    dependencies: {
      fetchJson: async (url) => {
        calls.fetches.push(url);
        return (
          response ?? {
            ok: true,
            status: 200,
            json: async () => ({
              audio: [{ lang: "pt" }, { lang: "en" }],
              subtitle: [{ lang: "pt" }],
            }),
          }
        );
      },
      timerApi: {
        setTimeout: (callback, delay) => {
          calls.timeouts.push(delay);
          callback();
        },
      },
    },
  });
  return { calls, controller, host, state };
}

test("validates the host and exposes an inert snapshot before probing", () => {
  assert.throws(
    () => createTrackProbeController({ host: {} }),
    /TrackProbeController host is missing/,
  );
  assert.ok(TRACK_PROBE_HOST_METHODS.includes("presentProbedTracks"));

  const { controller } = createHarness();
  assert.deepEqual(controller.snapshot(), { audioTracks: 0, probed: false, subtitleTracks: 0 });
  assert.equal(controller.hasProbedAudioTrack(0), false);
});

test("probes once, presents the tracks and auto-switches dual audio to AVPlayer", async () => {
  const { calls, controller } = createHarness();

  assert.equal(await controller.probe(), true);
  assert.deepEqual(calls.fetches, ["/api/gindex-tracks/movie/42"]);
  assert.equal(calls.presented.length, 1);
  assert.equal(calls.presented[0].sessionId, 3);
  assert.equal(typeof calls.presented[0].onAudioSelect, "function");
  assert.equal(controller.hasProbedAudioTrack(1), true);
  assert.deepEqual(calls.timeouts, [TRACK_PROBE_AUTO_SWITCH_DELAY_MS]);
  assert.deepEqual(calls.switches, [["audio", 1, 17.4, true]]);
  assert.deepEqual(controller.snapshot(), { audioTracks: 2, probed: true, subtitleTracks: 1 });

  assert.equal(await controller.probe(), false, "the probe is one-shot");
  assert.equal(calls.fetches.length, 1);
});

test("the probe is skipped by policy, content type, missing id, AVPlayer or teardown", async () => {
  const skipped = createHarness({
    state: { policy: { shouldProbeTracks: false, reason: "low-end" } },
  });
  assert.equal(await skipped.controller.probe(), false);
  assert.equal(skipped.calls.fetches.length, 0);
  assert.equal(skipped.controller.probed, true, "a policy skip still consumes the single attempt");

  const live = createHarness({ state: { contentType: "live" } });
  assert.equal(await live.controller.probe(), false);
  const noId = createHarness({ state: { contentId: "" } });
  assert.equal(await noId.controller.probe(), false);
  const avplayer = createHarness({ state: { usingAVPlayer: true } });
  assert.equal(await avplayer.controller.probe(), false);
  assert.equal(avplayer.controller.probed, false, "AVPlayer playback leaves the probe available");
  const destroyed = createHarness({ state: { destroyed: true } });
  assert.equal(await destroyed.controller.probe(), false);
});

test("API failures and superseded sessions never present or switch", async () => {
  const notOk = createHarness({ response: { ok: false, status: 404, json: async () => ({}) } });
  assert.equal(await notOk.controller.probe(), false);
  assert.equal(notOk.calls.presented.length, 0);

  const throwing = createHarness({
    response: {
      ok: true,
      status: 200,
      json: async () => {
        throw new Error("bad json");
      },
    },
  });
  assert.equal(await throwing.controller.probe(), false);

  const stale = createHarness();
  stale.host.isSessionCurrent = () => false;
  assert.equal(await stale.controller.probe(), false);
  assert.equal(stale.calls.presented.length, 0);
});

test("dual audio waits for the user when policy avoids speculative work without an AVPlayer preference", async () => {
  const waiting = createHarness({
    state: { policy: { shouldProbeTracks: true, avoidSpeculativeWork: true, reason: "battery" } },
  });
  assert.equal(await waiting.controller.probe(), true);
  assert.deepEqual(waiting.calls.switches, []);

  const preferred = createHarness({
    state: {
      policy: { shouldProbeTracks: true, avoidSpeculativeWork: true, reason: "battery" },
      prefersAVPlayer: true,
    },
  });
  assert.equal(await preferred.controller.probe(), true);
  assert.equal(preferred.calls.switches.length, 1);

  const single = createHarness({
    presentation: { audioTracks: [{ id: 0 }], subtitleTracks: [], selectedAudioTrack: 0 },
  });
  assert.equal(await single.controller.probe(), true);
  assert.deepEqual(single.calls.switches, [], "a single audio track needs no switch");
});

test("probed selections apply on an active AVPlayer or switch engines with the current position", async () => {
  const active = createHarness({ state: { usingAVPlayer: true, avPlayer: true } });
  assert.equal(await active.controller.selectAudioTrack(1), true);
  assert.deepEqual(active.calls.audioSelections, [1]);
  assert.equal(await active.controller.selectAudioTrack(7), true);
  assert.deepEqual(active.calls.audioSelections, [1], "unknown tracks are ignored");
  assert.equal(await active.controller.selectSubtitleTrack(-1), true);
  assert.deepEqual(active.calls.subtitleSelections, [-1]);
  assert.deepEqual(active.calls.switches, []);

  const native = createHarness({ state: { video: { currentTime: 30, paused: true } } });
  assert.equal(
    await native.controller.selectSubtitleTrack(-1),
    false,
    "disabling subtitles stays native",
  );
  assert.equal(await native.controller.selectSubtitleTrack(0), true);
  assert.equal(await native.controller.selectAudioTrack(1), true);
  assert.deepEqual(native.calls.switches, [
    ["subtitle", 0, 30, false],
    ["audio", 1, 30, false],
  ]);

  const switching = createHarness({ state: { switching: true } });
  assert.equal(await switching.controller.selectAudioTrack(1), false);
  assert.equal(await switching.controller.selectSubtitleTrack(0), false);
  assert.deepEqual(switching.calls.switches, []);
});

test("destroy stops the auto-switch that was waiting on its delay", async () => {
  const { calls, controller } = createHarness();
  controller.deps.timerApi = {
    setTimeout: (callback) => {
      controller.destroy();
      callback();
    },
  };

  assert.equal(await controller.probe(), true);
  assert.deepEqual(calls.switches, []);
});
