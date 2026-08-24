import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_STATE } from "../player/engine_contract.js";
import {
  createPlaybackStateObserver,
  PlaybackStateObserver,
} from "../player/playback_state_observer.js";

function createHarness(options = {}) {
  const lifecycle = [];
  const invalid = [];
  let now = 1_000;

  const observer = createPlaybackStateObserver({
    reportLifecycle(event, metadata) {
      lifecycle.push([event, metadata]);
    },
    logInvalid(transition) {
      invalid.push(transition);
    },
    machineOptions: {
      now: () => now++,
      ...options.machineOptions,
    },
    ...options,
  });

  return { observer, lifecycle, invalid };
}

test("starts a fresh selecting-source machine for every playback session", () => {
  const { observer, lifecycle } = createHarness();

  const first = observer.begin(7);
  assert.equal(first.accepted, true);
  assert.equal(observer.state, PLAYBACK_STATE.SELECTING_SOURCE);
  assert.equal(observer.snapshot().revision, 1);
  assert.deepEqual(first.metadata, { session_id: 7 });

  observer.observe(PLAYBACK_STATE.LOADING, "source_loading");
  observer.observe(PLAYBACK_STATE.PLAYING, "playback_started");
  assert.equal(observer.snapshot().revision, 3);

  const second = observer.begin(8);
  assert.equal(second.from, PLAYBACK_STATE.IDLE);
  assert.equal(second.to, PLAYBACK_STATE.SELECTING_SOURCE);
  assert.equal(observer.snapshot().revision, 1);
  assert.deepEqual(second.metadata, { session_id: 8 });

  assert.equal(lifecycle.filter(([event]) => event === "player_state_changed").length, 4);
});

test("reports accepted changes using the stable lifecycle metadata contract", () => {
  const { observer, lifecycle } = createHarness();

  observer.begin(9);
  const transition = observer.observe(PLAYBACK_STATE.LOADING, "source_loading", {
    stream_type: "hls",
  });

  assert.deepEqual(lifecycle.at(-1), [
    "player_state_changed",
    {
      from_state: PLAYBACK_STATE.SELECTING_SOURCE,
      to_state: PLAYBACK_STATE.LOADING,
      state_revision: 2,
      state_reason: "source_loading",
    },
  ]);
  assert.deepEqual(transition.metadata, { stream_type: "hls" });
});

test("invalid observations are logged and reported without mutating state", () => {
  const { observer, lifecycle, invalid } = createHarness();

  observer.begin(10);
  const transition = observer.observe(PLAYBACK_STATE.PLAYING, "playing_before_loading");

  assert.equal(transition.accepted, false);
  assert.equal(observer.state, PLAYBACK_STATE.SELECTING_SOURCE);
  assert.deepEqual(invalid, [transition]);
  assert.deepEqual(lifecycle.at(-1), [
    "player_state_transition_invalid",
    {
      from_state: PLAYBACK_STATE.SELECTING_SOURCE,
      to_state: PLAYBACK_STATE.PLAYING,
      state_revision: 1,
      state_reason: "playing_before_loading",
    },
  ]);
});

test("drops late browser events after cleanup while allowing repeated teardown", () => {
  const { observer, lifecycle } = createHarness();

  observer.begin(11);
  observer.observe(PLAYBACK_STATE.DESTROYED, "cleanup");
  const eventCountAfterCleanup = lifecycle.length;

  assert.equal(observer.observe(PLAYBACK_STATE.PLAYING, "late_media_playing"), null);
  assert.equal(lifecycle.length, eventCountAfterCleanup);

  const duplicate = observer.observe(PLAYBACK_STATE.DESTROYED, "duplicate_cleanup");
  assert.equal(duplicate.accepted, true);
  assert.equal(duplicate.changed, false);
  assert.equal(observer.state, PLAYBACK_STATE.DESTROYED);
});

test("returns null before a session begins", () => {
  const observer = createPlaybackStateObserver();

  assert.equal(observer.state, null);
  assert.equal(observer.snapshot(), null);
  assert.equal(observer.observe(PLAYBACK_STATE.LOADING, "too_early"), null);
});

test("diagnostic callback failures cannot interrupt playback state", () => {
  const observer = createPlaybackStateObserver({
    reportLifecycle() {
      throw new Error("telemetry down");
    },
    logInvalid() {
      throw new Error("logger down");
    },
    machineOptions: { now: () => 2_000 },
  });

  assert.doesNotThrow(() => observer.begin(12));
  assert.doesNotThrow(() => observer.observe(PLAYBACK_STATE.PLAYING, "invalid_but_safe"));
  assert.equal(observer.state, PLAYBACK_STATE.SELECTING_SOURCE);
});

test("validates observer boundaries", () => {
  assert.throws(
    () => new PlaybackStateObserver({ reportLifecycle: true }),
    /reportLifecycle boundary must be a function/,
  );
  assert.throws(
    () => new PlaybackStateObserver({ logInvalid: true }),
    /logInvalid boundary must be a function/,
  );
  assert.throws(
    () => new PlaybackStateObserver({ createMachine: true }),
    /createMachine boundary must be a function/,
  );
});
