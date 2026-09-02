import { assertEngineSelection, ENGINE_SELECTION, normalizeEngineId } from "./engine_contract.js";

/**
 * Host members every engine activation may rely on. Concrete activations
 * declare their own additional requirements on top of this baseline.
 */
export const PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  "getCurrentUrl",
  "getSessionId",
  "isSessionCurrent",
]);

function requiredFunction(value, name, owner) {
  if (typeof value !== "function") {
    throw new TypeError(`${owner} requires ${name}()`);
  }

  return value;
}

function optionalFunction(value, name, owner) {
  if (value == null) return null;
  return requiredFunction(value, name, owner);
}

function safeNotify(callback, ...args) {
  if (!callback) return;

  try {
    const result = callback(...args);
    if (result && typeof result.then === "function") {
      Promise.resolve(result).catch(() => {});
    }
  } catch {
    // Diagnostics must never replace an activation outcome.
  }
}

/**
 * Validates that a host object exposes every member an activation needs.
 * Activations stay independent from the player hook by consuming only this
 * explicit surface, which keeps them fakeable in unit tests.
 */
export function assertActivationHost(host, methods, owner = "PlaybackEngineActivation") {
  if (!host || typeof host !== "object") {
    throw new TypeError(`${owner} requires an activation host`);
  }

  const missing = methods.filter((method) => typeof host[method] !== "function");
  if (missing.length > 0) {
    throw new TypeError(`${owner} host is missing: ${missing.join(", ")}`);
  }

  return host;
}

function normalizeActivation(selection, activation, owner) {
  if (typeof activation === "function") {
    return { activate: activation };
  }

  if (activation && typeof activation.activate === "function") {
    return activation;
  }

  throw new TypeError(`${owner} activation for ${selection} must expose activate()`);
}

/**
 * Single entrypoint that turns an engine selection into concrete playback.
 *
 * The composition root registers one activation per selection. Extracted
 * engines own their construction, loading, registration and rollback; engines
 * that are still hosted by the hook register a thin delegate until they move.
 * The coordinator only owns dispatch, session guards, fallback for unknown
 * selections, error reporting and a diagnostics snapshot.
 */
export class PlaybackEngineActivation {
  constructor({
    activations = {},
    fallbackSelection = ENGINE_SELECTION.NATIVE,
    host,
    onError = null,
    onStateChange = null,
    onUnknownSelection = null,
  } = {}) {
    this.host = assertActivationHost(host, PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS);
    this.fallbackSelection = assertEngineSelection(fallbackSelection);
    this.onError = optionalFunction(onError, "onError", "PlaybackEngineActivation");
    this.onStateChange = optionalFunction(
      onStateChange,
      "onStateChange",
      "PlaybackEngineActivation",
    );
    this.onUnknownSelection = optionalFunction(
      onUnknownSelection,
      "onUnknownSelection",
      "PlaybackEngineActivation",
    );

    this.activations = new Map();
    this.destroyed = false;
    this.pending = 0;
    this.lastEngineId = null;
    this.lastSelection = null;

    for (const [selection, activation] of Object.entries(activations)) {
      this.register(selection, activation);
    }
  }

  register(selection, activation) {
    if (this.destroyed) throw new Error("PlaybackEngineActivation has been destroyed");

    assertEngineSelection(selection);
    this.activations.set(
      selection,
      normalizeActivation(selection, activation, "PlaybackEngineActivation"),
    );
    return this;
  }

  has(selection) {
    return !this.destroyed && this.activations.has(selection);
  }

  get(selection) {
    if (this.destroyed) return null;
    return this.activations.get(selection) ?? null;
  }

  selections() {
    return [...this.activations.keys()];
  }

  get active() {
    return this.pending > 0;
  }

  snapshot() {
    return Object.freeze({
      active: this.active,
      destroyed: this.destroyed,
      engineId: this.lastEngineId,
      pending: this.pending,
      selection: this.lastSelection,
      selections: this.selections(),
    });
  }

  activate(selection, options = {}) {
    if (this.destroyed) return Promise.resolve(false);

    const resolved = this.resolveSelection(selection);
    if (!resolved) return Promise.resolve(false);

    const request = Object.freeze({
      ...options,
      activate: (nextSelection, nextOptions = {}) => this.activate(nextSelection, nextOptions),
      engineId: normalizeEngineId(resolved.selection),
      requestedSelection: selection,
      selection: resolved.selection,
      sessionId: options.sessionId ?? this.host.getSessionId(),
      url: this.host.getCurrentUrl(),
    });

    if (!this.sessionIsCurrent(request)) return Promise.resolve(false);

    this.pending += 1;
    this.lastSelection = request.selection;
    this.lastEngineId = request.engineId;
    this.notifyState();

    let outcome;
    try {
      outcome = Promise.resolve(resolved.activation.activate(request));
    } catch (error) {
      outcome = Promise.reject(error);
    }

    return outcome
      .then((result) => (result === undefined ? true : result))
      .catch((error) => {
        safeNotify(this.onError, "activate", error, request);
        return false;
      })
      .finally(() => {
        this.pending = Math.max(0, this.pending - 1);
        this.notifyState();
      });
  }

  destroy() {
    if (this.destroyed) return false;

    this.destroyed = true;
    this.activations.clear();
    this.notifyState();
    return true;
  }

  resolveSelection(selection) {
    const activation = this.activations.get(selection);
    if (activation) return { activation, selection };

    safeNotify(this.onUnknownSelection, selection);
    const fallback = this.activations.get(this.fallbackSelection);
    return fallback ? { activation: fallback, selection: this.fallbackSelection } : null;
  }

  sessionIsCurrent(request) {
    try {
      return this.host.isSessionCurrent(request.sessionId) !== false;
    } catch (error) {
      safeNotify(this.onError, "session_guard", error, request);
      return false;
    }
  }

  notifyState() {
    safeNotify(this.onStateChange, this.snapshot());
  }
}

export function createPlaybackEngineActivation(options) {
  return new PlaybackEngineActivation(options);
}
