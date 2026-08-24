import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_STATE } from "../player/engine_contract.js";
import {
  createPlaybackStateMachine,
  PLAYBACK_TRANSITIONS,
  PlaybackStateMachine,
  PlaybackStateTransitionError,
} from "../player/playback_state_machine.js";

test("starts in an immutable idle snapshot", () => {
  const machine = createPlaybackStateMachine({ now: () => 1_000 });
  const snapshot = machine.snapshot();

  assert.equal(machine.state, PLAYBACK_STATE.IDLE);
  assert.equal(machine.previousState, null);
  assert.equal(machine.revision, 0);
  assert.deepEqual(snapshot, {
    state: PLAYBACK_STATE.IDLE,
    previousState: null,
    revision: 0,
    enteredAt: 1_000,
    reason: null,
    invalidTransitions: 0,
    history: [],
  });
  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.history), true);
  assert.equal(Object.isFrozen(PLAYBACK_TRANSITIONS), true);
});

test("accepts the canonical startup path with deterministic revisions", () => {
  let currentTime = 10;
  const machine = createPlaybackStateMachine({ now: () => currentTime++ });

  const transitions = [
    machine.transition(PLAYBACK_STATE.SELECTING_SOURCE, {
      reason: "session_started",
      metadata: { sessionId: 7 },
    }),
    machine.transition(PLAYBACK_STATE.LOADING, { reason: "engine_selected" }),
    machine.transition(PLAYBACK_STATE.READY, { reason: "media_ready" }),
    machine.transition(PLAYBACK_STATE.PLAYING, { reason: "playback_started" }),
  ];

  assert.deepEqual(
    transitions.map(({ accepted, changed, revision }) => ({
      accepted,
      changed,
      revision,
    })),
    [
      { accepted: true, changed: true, revision: 1 },
      { accepted: true, changed: true, revision: 2 },
      { accepted: true, changed: true, revision: 3 },
      { accepted: true, changed: true, revision: 4 },
    ],
  );
  assert.equal(machine.state, PLAYBACK_STATE.PLAYING);
  assert.equal(machine.previousState, PLAYBACK_STATE.READY);
  assert.equal(machine.revision, 4);
  assert.equal(machine.snapshot().enteredAt, 14);
  assert.equal(Object.isFrozen(transitions[0]), true);
  assert.equal(Object.isFrozen(transitions[0].metadata), true);
  assert.throws(() => {
    transitions[0].metadata.sessionId = 8;
  }, TypeError);
});

test("treats same-state observations as idempotent", () => {
  let currentTime = 20;
  const machine = createPlaybackStateMachine({ now: () => currentTime++ });
  const transition = machine.transition(PLAYBACK_STATE.IDLE, {
    reason: "duplicate_event",
  });

  assert.deepEqual(transition, {
    accepted: true,
    changed: false,
    from: PLAYBACK_STATE.IDLE,
    to: PLAYBACK_STATE.IDLE,
    revision: 0,
    at: 21,
    reason: "duplicate_event",
    metadata: {},
  });
  assert.equal(machine.previousState, null);
  assert.equal(machine.snapshot().enteredAt, 20);
  assert.equal(machine.snapshot().reason, null);
});

test("rejects an invalid observation without mutating playback state", () => {
  const invalid = [];
  const machine = createPlaybackStateMachine({
    now: () => 30,
    onInvalid: (transition) => invalid.push(transition),
  });

  const transition = machine.transition(PLAYBACK_STATE.PLAYING, {
    reason: "playing_before_source",
  });

  assert.equal(transition.accepted, false);
  assert.equal(transition.changed, false);
  assert.equal(machine.state, PLAYBACK_STATE.IDLE);
  assert.equal(machine.revision, 0);
  assert.equal(machine.invalidTransitions, 1);
  assert.deepEqual(invalid, [transition]);
  assert.deepEqual(machine.history(), [transition]);
});

test("strict mode raises after recording the rejected transition", () => {
  const machine = new PlaybackStateMachine({
    strict: true,
    now: () => 40,
  });

  assert.throws(
    () => machine.transition(PLAYBACK_STATE.PLAYING),
    (error) => {
      assert.equal(error instanceof PlaybackStateTransitionError, true);
      assert.equal(error.transition.from, PLAYBACK_STATE.IDLE);
      assert.equal(error.transition.to, PLAYBACK_STATE.PLAYING);
      return true;
    },
  );

  assert.equal(machine.state, PLAYBACK_STATE.IDLE);
  assert.equal(machine.invalidTransitions, 1);
  assert.equal(machine.history().length, 1);
});

test("destroyed is terminal while repeated teardown remains idempotent", () => {
  const machine = createPlaybackStateMachine({ now: () => 50 });

  assert.equal(machine.transition(PLAYBACK_STATE.DESTROYED, { reason: "cleanup" }).accepted, true);

  const invalid = machine.transition(PLAYBACK_STATE.SELECTING_SOURCE, {
    reason: "late_retry",
  });
  const duplicate = machine.transition(PLAYBACK_STATE.DESTROYED, {
    reason: "duplicate_cleanup",
  });

  assert.equal(invalid.accepted, false);
  assert.equal(duplicate.accepted, true);
  assert.equal(duplicate.changed, false);
  assert.equal(machine.state, PLAYBACK_STATE.DESTROYED);
  assert.equal(machine.revision, 1);
});

test("keeps only the newest bounded transition history", () => {
  let currentTime = 60;
  const machine = createPlaybackStateMachine({
    historyLimit: 2,
    now: () => currentTime++,
  });

  machine.transition(PLAYBACK_STATE.SELECTING_SOURCE);
  machine.transition(PLAYBACK_STATE.LOADING);
  machine.transition(PLAYBACK_STATE.READY);

  const history = machine.history();
  assert.equal(history.length, 2);
  assert.deepEqual(
    history.map(({ from, to }) => [from, to]),
    [
      [PLAYBACK_STATE.SELECTING_SOURCE, PLAYBACK_STATE.LOADING],
      [PLAYBACK_STATE.LOADING, PLAYBACK_STATE.READY],
    ],
  );
  assert.equal(Object.isFrozen(history), true);
  assert.throws(() => history.push({}), TypeError);
});

test("supports stall and recovery paths used by adaptive playback", () => {
  const machine = createPlaybackStateMachine({ now: () => 70 });

  const path = [
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.STALLED,
    PLAYBACK_STATE.RECOVERING,
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.PLAYING,
  ];

  for (const state of path) {
    assert.equal(machine.transition(state).accepted, true);
  }

  assert.equal(machine.state, PLAYBACK_STATE.PLAYING);
  assert.equal(machine.invalidTransitions, 0);
});

test("validates states, boundaries, and the injected clock", () => {
  assert.throws(
    () => createPlaybackStateMachine({ initialState: "invented" }),
    /Unknown playback initial state/,
  );
  assert.throws(
    () => createPlaybackStateMachine({ historyLimit: 0 }),
    /historyLimit must be a positive integer/,
  );
  assert.throws(
    () => createPlaybackStateMachine({ now: "later" }),
    /now boundary must be a function/,
  );
  assert.throws(
    () => createPlaybackStateMachine({ onInvalid: true }),
    /onInvalid boundary must be a function/,
  );
  assert.throws(
    () => createPlaybackStateMachine({ now: () => Number.NaN }),
    /clock must return a finite timestamp/,
  );

  const machine = createPlaybackStateMachine({ now: () => 80 });
  assert.throws(() => machine.transition("invented"), /Unknown playback target state/);
});

test("invalid observers cannot become a playback failure source", () => {
  const machine = createPlaybackStateMachine({
    now: () => 90,
    onInvalid() {
      throw new Error("telemetry unavailable");
    },
  });

  assert.doesNotThrow(() => machine.transition(PLAYBACK_STATE.PLAYING));
  assert.equal(machine.invalidTransitions, 1);
});
