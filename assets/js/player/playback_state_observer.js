import { PLAYBACK_STATE } from "./engine_contract.js";
import { createPlaybackStateMachine } from "./playback_state_machine.js";

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`Playback state ${name} boundary must be a function`);
  }
  return value;
}

function safeCall(callback, ...args) {
  if (!callback) return;

  try {
    callback(...args);
  } catch {
    // Diagnostics must never become a playback failure source.
  }
}

function changedMetadata(transition) {
  return {
    from_state: transition.from,
    to_state: transition.to,
    state_revision: transition.revision,
    state_reason: transition.reason,
  };
}

/**
 * Converts pure state-machine transitions into bounded player lifecycle events.
 *
 * The observer owns one machine per playback session. It deliberately rejects
 * late non-terminal events after cleanup without reporting them as invalid,
 * because browser media events may still arrive while listeners are draining.
 */
export class PlaybackStateObserver {
  constructor({
    reportLifecycle = null,
    logInvalid = null,
    createMachine = createPlaybackStateMachine,
    machineOptions = {},
  } = {}) {
    this._reportLifecycle = optionalCallback(reportLifecycle, "reportLifecycle");
    this._logInvalid = optionalCallback(logInvalid, "logInvalid");
    this._createMachine = optionalCallback(createMachine, "createMachine");
    this._machineOptions = { ...machineOptions };
    this._machine = null;
  }

  get state() {
    return this._machine?.state ?? null;
  }

  begin(sessionId) {
    this._machine = this._createMachine({
      ...this._machineOptions,
      onInvalid: (transition) => this._handleInvalid(transition),
    });

    return this.observe(PLAYBACK_STATE.SELECTING_SOURCE, "session_started", {
      session_id: sessionId,
    });
  }

  observe(nextState, reason, metadata = {}) {
    const machine = this._machine;
    if (!machine) return null;

    if (machine.state === PLAYBACK_STATE.DESTROYED && nextState !== PLAYBACK_STATE.DESTROYED) {
      return null;
    }

    const transition = machine.transition(nextState, { reason, metadata });

    if (transition.accepted && transition.changed) {
      safeCall(this._reportLifecycle, "player_state_changed", changedMetadata(transition));
    }

    return transition;
  }

  snapshot() {
    return this._machine?.snapshot() ?? null;
  }

  _handleInvalid(transition) {
    safeCall(this._logInvalid, transition);
    safeCall(this._reportLifecycle, "player_state_transition_invalid", changedMetadata(transition));
  }
}

export function createPlaybackStateObserver(options) {
  return new PlaybackStateObserver(options);
}
