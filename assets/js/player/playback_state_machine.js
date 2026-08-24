import { PLAYBACK_STATE } from "./engine_contract.js";

const STATES = new Set(Object.values(PLAYBACK_STATE));

export const PLAYBACK_TRANSITIONS = Object.freeze({
  [PLAYBACK_STATE.IDLE]: Object.freeze([PLAYBACK_STATE.SELECTING_SOURCE, PLAYBACK_STATE.DESTROYED]),
  [PLAYBACK_STATE.SELECTING_SOURCE]: Object.freeze([
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.LOADING]: Object.freeze([
    PLAYBACK_STATE.READY,
    PLAYBACK_STATE.PLAYING,
    PLAYBACK_STATE.STALLED,
    PLAYBACK_STATE.RECOVERING,
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.READY]: Object.freeze([
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.PLAYING,
    PLAYBACK_STATE.STALLED,
    PLAYBACK_STATE.RECOVERING,
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.PLAYING]: Object.freeze([
    PLAYBACK_STATE.READY,
    PLAYBACK_STATE.STALLED,
    PLAYBACK_STATE.RECOVERING,
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.STALLED]: Object.freeze([
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.PLAYING,
    PLAYBACK_STATE.RECOVERING,
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.RECOVERING]: Object.freeze([
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.LOADING,
    PLAYBACK_STATE.READY,
    PLAYBACK_STATE.PLAYING,
    PLAYBACK_STATE.STALLED,
    PLAYBACK_STATE.TERMINAL,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.TERMINAL]: Object.freeze([
    PLAYBACK_STATE.SELECTING_SOURCE,
    PLAYBACK_STATE.DESTROYED,
  ]),
  [PLAYBACK_STATE.DESTROYED]: Object.freeze([]),
});

const TRANSITION_SETS = new Map(
  Object.entries(PLAYBACK_TRANSITIONS).map(([state, transitions]) => [state, new Set(transitions)]),
);

function assertState(state, field = "state") {
  if (!STATES.has(state)) {
    throw new TypeError(`Unknown playback ${field}: ${String(state)}`);
  }
}

function normalizeHistoryLimit(value) {
  if (!Number.isInteger(value) || value < 1) {
    throw new TypeError("Playback state historyLimit must be a positive integer");
  }

  return value;
}

function normalizeNow(now) {
  if (typeof now !== "function") {
    throw new TypeError("Playback state now boundary must be a function");
  }

  return now;
}

function normalizeOnInvalid(onInvalid) {
  if (onInvalid != null && typeof onInvalid !== "function") {
    throw new TypeError("Playback state onInvalid boundary must be a function");
  }

  return onInvalid;
}

function timestamp(now) {
  const value = Number(now());
  if (!Number.isFinite(value)) {
    throw new TypeError("Playback state clock must return a finite timestamp");
  }

  return value;
}

function freezeMetadata(metadata) {
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return Object.freeze({});
  }

  return Object.freeze({ ...metadata });
}

function normalizeReason(reason) {
  if (reason == null) return null;
  return String(reason).slice(0, 160);
}

function freezeTransition(transition) {
  return Object.freeze({
    ...transition,
    metadata: freezeMetadata(transition.metadata),
  });
}

export class PlaybackStateTransitionError extends Error {
  constructor(transition) {
    super(`Invalid playback state transition: ${transition.from} -> ${transition.to}`);
    this.name = "PlaybackStateTransitionError";
    this.transition = transition;
  }
}

/**
 * Pure, bounded playback lifecycle state machine.
 *
 * The default mode is observational: an invalid transition is rejected and
 * reported without mutating state. Strict mode is available for isolated tests
 * and future enforcement once production telemetry proves the graph complete.
 */
export class PlaybackStateMachine {
  constructor({
    initialState = PLAYBACK_STATE.IDLE,
    historyLimit = 64,
    now = () => Date.now(),
    strict = false,
    onInvalid = null,
  } = {}) {
    assertState(initialState, "initial state");

    this._historyLimit = normalizeHistoryLimit(historyLimit);
    this._now = normalizeNow(now);
    this._strict = strict === true;
    this._onInvalid = normalizeOnInvalid(onInvalid);

    const startedAt = timestamp(this._now);
    this._state = initialState;
    this._previousState = null;
    this._revision = 0;
    this._enteredAt = startedAt;
    this._reason = null;
    this._invalidTransitions = 0;
    this._history = [];
  }

  get state() {
    return this._state;
  }

  get previousState() {
    return this._previousState;
  }

  get revision() {
    return this._revision;
  }

  get invalidTransitions() {
    return this._invalidTransitions;
  }

  canTransition(nextState) {
    assertState(nextState, "target state");
    if (nextState === this._state) return true;
    return TRANSITION_SETS.get(this._state)?.has(nextState) === true;
  }

  transition(nextState, { reason = null, metadata = {} } = {}) {
    assertState(nextState, "target state");

    const from = this._state;
    const at = timestamp(this._now);
    const accepted = this.canTransition(nextState);
    const changed = accepted && nextState !== from;
    const nextRevision = changed ? this._revision + 1 : this._revision;

    const transition = freezeTransition({
      accepted,
      changed,
      from,
      to: nextState,
      revision: nextRevision,
      at,
      reason: normalizeReason(reason),
      metadata,
    });

    if (!accepted) {
      this._invalidTransitions += 1;
      this._remember(transition);
      this._notifyInvalid(transition);

      if (this._strict) {
        throw new PlaybackStateTransitionError(transition);
      }

      return transition;
    }

    if (changed) {
      this._previousState = from;
      this._state = nextState;
      this._revision = nextRevision;
      this._enteredAt = at;
      this._reason = transition.reason;
    }

    this._remember(transition);
    return transition;
  }

  history() {
    return Object.freeze([...this._history]);
  }

  snapshot() {
    return Object.freeze({
      state: this._state,
      previousState: this._previousState,
      revision: this._revision,
      enteredAt: this._enteredAt,
      reason: this._reason,
      invalidTransitions: this._invalidTransitions,
      history: this.history(),
    });
  }

  _remember(transition) {
    this._history.push(transition);

    if (this._history.length > this._historyLimit) {
      this._history.splice(0, this._history.length - this._historyLimit);
    }
  }

  _notifyInvalid(transition) {
    if (!this._onInvalid) return;

    try {
      this._onInvalid(transition);
    } catch {
      // Observability callbacks must never become a playback failure source.
    }
  }
}

export function createPlaybackStateMachine(options) {
  return new PlaybackStateMachine(options);
}
