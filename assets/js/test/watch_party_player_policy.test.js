import assert from "node:assert/strict";
import test from "node:test";

import {
  createWatchPartyPlayerPolicy,
  VIEWER_PLAY_LABEL,
  VIEWER_SPEED_LABEL,
  VIEWER_TRANSPORT_NOTICE,
} from "../watch_party/player_policy.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createControl() {
  const classes = new Set();
  return {
    attributes: {},
    classes,
    classList: {
      add: (...names) => {
        for (const name of names) classes.add(name);
      },
    },
    disabled: false,
    setAttribute(name, value) {
      this.attributes[name] = value;
    },
  };
}

function createHarness({
  enabled = true,
  role = "viewer",
  engine = null,
  videoPaused = false,
} = {}) {
  const controls = {
    "#play-pause-btn": createControl(),
    "#progress-container": createControl(),
    "#speed-btn": createControl(),
  };
  const calls = { intentionalPauses: 0, notices: [], systemStates: [], videoPauses: 0 };
  const video = {
    paused: videoPaused,
    pause() {
      calls.videoPauses += 1;
      this.paused = true;
    },
  };
  const policy = createWatchPartyPlayerPolicy({
    enabled,
    role,
    root: { querySelector: (selector) => controls[selector] ?? null },
    getVideo: () => video,
    getManagedEngine: () => engine,
    getNativeBufferManager: () => ({
      markIntentionalPause: () => {
        calls.intentionalPauses += 1;
      },
    }),
    setPlaybackSystemState: (state) => calls.systemStates.push(state),
    showNotice: (message) => calls.notices.push(message),
    logger: silentLogger,
  });
  return { calls, controls, policy, video };
}

test("roles resolve only while a party is enabled", () => {
  const viewer = createHarness().policy;
  const host = createHarness({ role: "host" }).policy;
  const solo = createHarness({ enabled: false, role: "viewer" }).policy;

  assert.equal(viewer.isViewer, true);
  assert.equal(viewer.isHost, false);
  assert.equal(host.isHost, true);
  assert.equal(solo.isViewer, false);
  assert.equal(solo.isHost, false);
  assert.deepEqual(solo.snapshot(), { enabled: false, held: false, role: "viewer" });
  assert.equal(createWatchPartyPlayerPolicy({ enabled: true, role: "" }).role, "none");
});

test("viewers lose local transport unless the command is remote", () => {
  const { calls, policy } = createHarness();

  assert.equal(policy.canControlTransport(), false);
  assert.equal(policy.canControlTransport({ remote: true }), true);
  assert.equal(policy.rejectViewerTransportControl(), true);
  assert.equal(policy.rejectViewerTransportControl({ remote: true }), false);
  assert.deepEqual(calls.notices, [VIEWER_TRANSPORT_NOTICE]);
  assert.equal(policy.allowsNativeTouchControls(), false);

  const host = createHarness({ role: "host" });
  assert.equal(host.policy.canControlTransport(), true);
  assert.equal(host.policy.rejectViewerTransportControl(), false);
  assert.equal(host.policy.allowsNativeTouchControls(), true);
  assert.deepEqual(host.calls.notices, []);
});

test("the control policy disables viewer controls and leaves hosts untouched", () => {
  const viewer = createHarness();
  assert.equal(viewer.policy.applyControlPolicy(), true);
  assert.equal(viewer.controls["#play-pause-btn"].disabled, true);
  assert.equal(viewer.controls["#play-pause-btn"].attributes["aria-label"], VIEWER_PLAY_LABEL);
  assert.ok(viewer.controls["#play-pause-btn"].classes.has("cursor-not-allowed"));
  assert.equal(viewer.controls["#progress-container"].attributes["aria-disabled"], "true");
  assert.ok(viewer.controls["#progress-container"].classes.has("pointer-events-none"));
  assert.equal(viewer.controls["#speed-btn"].attributes["aria-label"], VIEWER_SPEED_LABEL);

  const host = createHarness({ role: "host" });
  assert.equal(host.policy.applyControlPolicy(), false);
  assert.equal(host.controls["#play-pause-btn"].disabled, false);

  const rootless = createWatchPartyPlayerPolicy({ enabled: true, role: "viewer" });
  assert.equal(rootless.applyControlPolicy(), false);
});

test("sync hold pauses the managed engine or the native element and reports paused state", () => {
  const paused = [];
  const engine = {
    isPlaying: () => true,
    pause: () => {
      paused.push("engine");
      return Promise.resolve();
    },
  };
  const managed = createHarness({ engine });
  assert.equal(managed.policy.setSyncHold(true), true);
  assert.equal(managed.policy.held, true);
  assert.deepEqual(paused, ["engine"]);
  assert.deepEqual(managed.calls.systemStates, ["paused"]);
  assert.equal(managed.calls.videoPauses, 0);
  assert.equal(managed.policy.shouldReapplyHoldOnPlay(), true);

  const native = createHarness();
  native.policy.setSyncHold(true);
  assert.equal(native.calls.videoPauses, 1);
  assert.equal(native.calls.intentionalPauses, 1);
  assert.equal(native.video.paused, true);

  native.policy.setSyncHold(true);
  assert.equal(native.calls.videoPauses, 1, "an already paused element is left alone");

  assert.equal(native.policy.setSyncHold(false), true);
  assert.equal(native.policy.held, false);
  assert.equal(native.policy.shouldReapplyHoldOnPlay(), false);
});

test("hosts and solo playback ignore sync holds and swallow engine pause failures for viewers", () => {
  const host = createHarness({ role: "host", videoPaused: false });
  assert.equal(host.policy.setSyncHold(true), true);
  assert.equal(host.policy.held, false);
  assert.equal(host.calls.videoPauses, 0);
  assert.deepEqual(host.calls.systemStates, []);

  const throwing = createHarness({
    engine: {
      isPlaying: () => {
        throw new Error("engine gone");
      },
    },
  });
  assert.equal(throwing.policy.setSyncHold(true), true);
  assert.deepEqual(throwing.calls.systemStates, ["paused"], "the hold still reports paused");
});
