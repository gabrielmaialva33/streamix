export const PLAYBACK_ENGINE_TRANSITION_PHASE = Object.freeze({
  IDLE: "idle",
  CAPTURING: "capturing",
  PREPARING: "preparing",
  RELEASING: "releasing",
  DRAINING: "draining",
  CREATING: "creating",
  INITIALIZING: "initializing",
  LOADING: "loading",
  REGISTERING: "registering",
  RESTORING: "restoring",
  ACTIVATING: "activating",
  COMPLETING: "completing",
  COMPLETED: "completed",
  FAILED: "failed",
  STALE: "stale",
  CANCELLED: "cancelled",
  DESTROYED: "destroyed",
});

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlaybackEngineTransitionController requires ${name}()`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`PlaybackEngineTransitionController ${name} must be a function`);
  }

  return value;
}

function requiredTransitionCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`Playback engine transition requires ${name}()`);
  }

  return value;
}

function safeNotify(callback, ...args) {
  if (!callback) return;

  try {
    const result = callback(...args);
    if (result && typeof result.then === "function") {
      Promise.resolve(result).catch(() => {});
    }
  } catch {
    // Diagnostics and observers must never replace a transition failure.
  }
}

function transitionKey(value) {
  const key = String(value ?? "engine-transition").trim();
  return key || "engine-transition";
}

function errorName(error) {
  return typeof error?.name === "string" && error.name ? error.name : null;
}

/**
 * Serializes one cross-engine transition at a time.
 *
 * Concrete engine construction, DOM mutation, product policy and UI callbacks
 * stay injected by the composition root. This controller owns ordering,
 * session/revision guards, provisional-engine cleanup and one terminal outcome.
 */
export class PlaybackEngineTransitionController {
  constructor({
    beginSession,
    isSessionCurrent,
    drainTeardown,
    destroyEngine,
    onError = null,
    onStateChange = null,
  } = {}) {
    this._beginSession = requiredCallback(beginSession, "beginSession");
    this._isSessionCurrent = requiredCallback(isSessionCurrent, "isSessionCurrent");
    this._drainTeardown = requiredCallback(drainTeardown, "drainTeardown");
    this._destroyEngine = requiredCallback(destroyEngine, "destroyEngine");
    this._onError = optionalCallback(onError, "onError");
    this._onStateChange = optionalCallback(onStateChange, "onStateChange");

    this._activeContext = null;
    this._activePromise = null;
    this._destroyed = false;
    this._phase = PLAYBACK_ENGINE_TRANSITION_PHASE.IDLE;
    this._revision = 0;
    this._lastErrorName = null;
  }

  get active() {
    return this._activePromise != null;
  }

  get destroyed() {
    return this._destroyed;
  }

  snapshot() {
    return Object.freeze({
      active: this.active,
      destroyed: this._destroyed,
      errorName: this._lastErrorName,
      key: this._activeContext?.key ?? null,
      phase: this._phase,
      revision: this._revision,
      sessionId: this._activeContext?.sessionId ?? null,
    });
  }

  transition(options = {}) {
    if (this._destroyed) return Promise.resolve(false);

    requiredTransitionCallback(options.createEngine, "createEngine");
    requiredTransitionCallback(options.activateEngine, "activateEngine");

    if (this._activePromise) {
      if (this._activeContext?.cancelled) {
        return this._activePromise.then(() => this.transition(options));
      }
      return this._activePromise;
    }

    const context = {
      cancelled: false,
      capture: null,
      cleaned: false,
      committed: false,
      engine: null,
      key: transitionKey(options.key),
      options,
      revision: ++this._revision,
      sessionId: null,
    };

    this._activeContext = context;
    this._lastErrorName = null;
    const transitionPromise = this._run(context).finally(() => {
      if (this._activeContext === context) {
        this._activeContext = null;
        this._activePromise = null;
        if (!this._destroyed && this._phase !== PLAYBACK_ENGINE_TRANSITION_PHASE.DESTROYED) {
          this._phase = PLAYBACK_ENGINE_TRANSITION_PHASE.IDLE;
          this._notifyState();
        }
      }
    });

    this._activePromise = transitionPromise;
    this._notifyState();
    return transitionPromise;
  }

  recover(options = {}) {
    if (this._destroyed) return Promise.resolve(false);

    requiredTransitionCallback(options.activateNative, "activateNative");
    if (options.sourceSessionId == null) {
      throw new TypeError("Playback engine recovery requires sourceSessionId");
    }

    const key = transitionKey(options.key);
    if (this._activePromise) {
      const activeContext = this._activeContext;
      if (
        activeContext?.mode === "recovery" &&
        activeContext.sourceSessionId === options.sourceSessionId &&
        activeContext.key === key
      ) {
        return this._activePromise;
      }
      if (
        activeContext?.cancelled ||
        activeContext?.committed ||
        this._phase === PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETED ||
        this._phase === PLAYBACK_ENGINE_TRANSITION_PHASE.FAILED
      ) {
        // A failure handler may request recovery while its own transition is
        // still settling. Queue the recovery behind that promise instead of
        // handing the pending transition back, which would deadlock a handler
        // that awaits it.
        return this._activePromise.then(() => this.recover(options));
      }
      return this._activePromise;
    }

    if (!this._sessionIsCurrent(options.sourceSessionId)) {
      return Promise.resolve(false);
    }

    const context = {
      cancelled: false,
      capture: null,
      cleaned: false,
      committed: false,
      engine: options.engine ?? null,
      key,
      mode: "recovery",
      options,
      released: false,
      revision: ++this._revision,
      sessionId: null,
      sourceSessionId: options.sourceSessionId,
    };

    this._activeContext = context;
    this._lastErrorName = null;
    const recoveryPromise = this._runRecovery(context).finally(() => {
      if (this._activeContext === context) {
        this._activeContext = null;
        this._activePromise = null;
        if (!this._destroyed && this._phase !== PLAYBACK_ENGINE_TRANSITION_PHASE.DESTROYED) {
          this._phase = PLAYBACK_ENGINE_TRANSITION_PHASE.IDLE;
          this._notifyState();
        }
      }
    });

    this._activePromise = recoveryPromise;
    this._notifyState();
    return recoveryPromise;
  }

  cancel(reason = "cancelled") {
    const context = this._activeContext;
    if (!context || context.cancelled) return Promise.resolve(false);

    context.cancelled = true;
    this._revision += 1;
    this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.CANCELLED);
    safeNotify(context.options.onCancel, context, reason);
    return this._cancelContext(context).then(() => true);
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this._revision += 1;
    const context = this._activeContext;
    if (context) {
      context.cancelled = true;
      void this._cancelContext(context);
    }
    this._phase = PLAYBACK_ENGINE_TRANSITION_PHASE.DESTROYED;
    this._notifyState();
    return true;
  }

  async _run(context) {
    try {
      context.capture = await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.CAPTURING,
        context.options.capture,
      );
      if (!this._revisionIsCurrent(context)) return this._finishStale(context);

      context.sessionId = context.options.sessionId ?? this._beginSession();
      if (!this._isCurrent(context)) return this._finishStale(context);
      this._notifyState();

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.PREPARING,
        context.options.prepare,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.RELEASING,
        context.options.releasePrevious,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.DRAINING);
      await this._drainTeardown(context);
      if (!this._isCurrent(context)) return this._finishStale(context);

      context.engine = await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.CREATING,
        context.options.createEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);
      if (!context.engine) throw new Error("Playback engine transition created no engine");

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.INITIALIZING,
        context.options.initializeEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.LOADING,
        context.options.loadEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.REGISTERING,
        context.options.registerEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.RESTORING,
        context.options.restoreEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.ACTIVATING,
        context.options.activateEngine,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      const result = await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETING,
        context.options.complete,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      context.committed = true;
      this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETED);
      return result === undefined ? true : result;
    } catch (error) {
      if (context.sessionId != null && !this._isCurrent(context)) {
        return this._finishStale(context);
      }
      return this._finishFailure(context, error);
    }
  }

  async _runRecovery(context) {
    try {
      context.capture = await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.CAPTURING,
        context.options.capture,
      );
      if (!this._sourceIsCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.PREPARING,
        context.options.prepare,
      );
      if (!this._sourceIsCurrent(context)) return this._finishStale(context);

      this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.RELEASING);
      await this._releaseRecoverySource(context, true);
      if (!this._sourceIsCurrent(context)) return this._finishStale(context);

      this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.DRAINING);
      await this._drainTeardown(context);
      if (!this._sourceIsCurrent(context)) return this._finishStale(context);

      context.sessionId = this._beginSession();
      if (!this._isCurrent(context)) return this._finishStale(context);
      this._notifyState();

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.RESTORING,
        context.options.restoreNative,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.ACTIVATING,
        context.options.activateNative,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      const result = await this._step(
        context,
        PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETING,
        context.options.complete,
      );
      if (!this._isCurrent(context)) return this._finishStale(context);

      context.committed = true;
      this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.COMPLETED);
      return result === undefined ? true : result;
    } catch (error) {
      const current =
        context.sessionId == null ? this._sourceIsCurrent(context) : this._isCurrent(context);
      if (!current) return this._finishStale(context);
      return this._finishRecoveryFailure(context, error);
    }
  }

  async _step(context, phase, callback) {
    this._setPhase(phase);
    if (typeof callback !== "function") return undefined;
    return callback(context);
  }

  async _finishStale(context) {
    this._setPhase(
      this._destroyed
        ? PLAYBACK_ENGINE_TRANSITION_PHASE.DESTROYED
        : context.cancelled
          ? PLAYBACK_ENGINE_TRANSITION_PHASE.CANCELLED
          : PLAYBACK_ENGINE_TRANSITION_PHASE.STALE,
    );
    safeNotify(context.options.onStale, context);
    await this._cancelContext(context);
    return false;
  }

  async _finishFailure(context, error) {
    this._lastErrorName = errorName(error);
    this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.FAILED);

    await this._cleanupEngine(context);

    try {
      if (typeof context.options.onFailure === "function") {
        await context.options.onFailure(error, context);
      }
    } catch (failureError) {
      safeNotify(this._onError, "failure_handler", failureError, context);
    }

    safeNotify(this._onError, "transition", error, context);
    return false;
  }

  async _finishRecoveryFailure(context, error) {
    this._lastErrorName = errorName(error);
    this._setPhase(PLAYBACK_ENGINE_TRANSITION_PHASE.FAILED);

    await this._cancelContext(context);

    try {
      if (typeof context.options.onFailure === "function") {
        await context.options.onFailure(error, context);
      }
    } catch (failureError) {
      safeNotify(this._onError, "failure_handler", failureError, context);
    }

    safeNotify(this._onError, "recovery", error, context);
    return false;
  }

  async _cancelContext(context) {
    if (context?.mode !== "recovery") {
      return this._cleanupEngine(context);
    }

    await this._releaseRecoverySource(context, false);
    try {
      await this._drainTeardown(context);
    } catch (error) {
      safeNotify(this._onError, "drain_teardown", error, context);
    }
    return true;
  }

  async _releaseRecoverySource(context, throwOnError) {
    if (!context?.engine || context.released) return false;

    context.released = true;
    let releaseError = null;

    try {
      if (typeof context.options.releasePrevious === "function") {
        await context.options.releasePrevious(context);
      }
    } catch (error) {
      releaseError = error;
      safeNotify(this._onError, "release_previous", error, context);
    }

    const destroyEngine =
      typeof context.options.destroyEngine === "function"
        ? context.options.destroyEngine
        : this._destroyEngine;

    try {
      await destroyEngine(context.engine, context);
    } catch (error) {
      releaseError ??= error;
      safeNotify(this._onError, "destroy_engine", error, context);
    }

    context.engine = null;
    if (throwOnError && releaseError) throw releaseError;
    return true;
  }

  async _cleanupEngine(context) {
    if (!context?.engine || context.committed || context.cleaned) return false;

    context.cleaned = true;
    try {
      if (typeof context.options.rollbackEngine === "function") {
        await context.options.rollbackEngine(context);
      }
    } catch (error) {
      safeNotify(this._onError, "rollback", error, context);
    }

    const destroyEngine =
      typeof context.options.destroyEngine === "function"
        ? context.options.destroyEngine
        : this._destroyEngine;

    try {
      await destroyEngine(context.engine, context);
    } catch (error) {
      safeNotify(this._onError, "destroy_engine", error, context);
    }
    return true;
  }

  _isCurrent(context) {
    if (!this._revisionIsCurrent(context) || context.sessionId == null) return false;
    return this._sessionIsCurrent(context.sessionId, context);
  }

  _sourceIsCurrent(context) {
    return (
      this._revisionIsCurrent(context) &&
      context.sourceSessionId != null &&
      this._sessionIsCurrent(context.sourceSessionId, context)
    );
  }

  _sessionIsCurrent(sessionId, context = null) {
    try {
      return this._isSessionCurrent(sessionId) !== false;
    } catch (error) {
      safeNotify(this._onError, "session_guard", error, context);
      return false;
    }
  }

  _revisionIsCurrent(context) {
    return (
      !this._destroyed &&
      !context.cancelled &&
      this._activeContext === context &&
      context.revision === this._revision
    );
  }

  _setPhase(phase) {
    this._phase = phase;
    this._notifyState();
  }

  _notifyState() {
    safeNotify(this._onStateChange, this.snapshot());
  }
}

export function createPlaybackEngineTransitionController(options) {
  return new PlaybackEngineTransitionController(options);
}
