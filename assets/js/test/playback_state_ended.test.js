import assert from "node:assert/strict";
import test from "node:test";

import { PLAYBACK_STATE } from "../player/engine_contract.js";
import { createPlaybackStateMachine } from "../player/playback_state_machine.js";
import { createPlaybackStateObserver } from "../player/playback_state_observer.js";

test("models natural media completion separately from terminal failure", () => {
  const machine = createPlaybackStateMachine({ now: () => 100 });

  machine.transition(PLAYBACK_STATE.SELECTING_SOURCE);
  machine.transition(PLAYBACK_STATE.LOADING);
  machine.transition(PLAYBACK_STATE.PLAYING);
  const ended = machine.transition(PLAYBACK_STATE.ENDED, {
    reason: "media_ended",
  });

  assert.equal(ended.accepted, true);
  assert.equal(ended.changed, true);
  assert.equal(machine.state, PLAYBACK_STATE.ENDED);
  assert.equal(machine.snapshot().reason, "media_ended");
  assert.equal(machine.canTransition(PLAYBACK_STATE.SELECTING_SOURCE), true);
  assert.equal(machine.canTransition(PLAYBACK_STATE.READY), false);
});

test("allows a completed session to select a new source", () => {
  const machine = createPlaybackStateMachine({ now: () => 200 });

  for (const state of [
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.READY,
    PLAYBACK_STATE.ENDED,
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.LOADING,
  ]) {
    assert.equal(machine.transition(state).accepted, true);
  }

  assert.equal(machine.state, PLAYBACK_STATE.LOADING);
  assert.equal(machine.invalidTransitions, 0);
});

test("the lifecycle observer reports ended as a normal accepted transition", () => {
  const lifecycle = [];
  const observer = createPlaybackStateObserver({
    reportLifecycle: (event, metadata) => lifecycle.push([event, metadata]),
    machineOptions: { now: () => 300 },
  });

  observer.begin(7);
  observer.observe(PLAYBACK_STATE.LOADING, "source_loading");
  observer.observe(PLAYBACK_STATE.PLAYING, "media_playing");
  const transition = observer.observe(PLAYBACK_STATE.ENDED, "media_ended");

  assert.equal(transition.accepted, true);
  assert.equal(observer.state, PLAYBACK_STATE.ENDED);
  assert.deepEqual(lifecycle.at(-1), [
    "player_state_changed",
    {
      from_state: PLAYBACK_STATE.PLAYING,
      to_state: PLAYBACK_STATE.ENDED,
      state_revision: 4,
      state_reason: "media_ended",
    },
  ]);
});
