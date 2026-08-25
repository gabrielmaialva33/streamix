import {
  assertPlaybackEngine,
  ENGINE_ID,
  normalizeEngineId,
  playbackEngineCapabilities,
} from "./engine_contract.js";

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`EngineRegistry ${name} must be a function`);
  }
  return value;
}

function safeNotify(callback, ...args) {
  if (!callback) return;
  try {
    callback(...args);
  } catch {
    // Diagnostics must never become an engine lifecycle failure source.
  }
}

function normalizeId(id) {
  const normalized = normalizeEngineId(id);
  if (normalized === ENGINE_ID.UNKNOWN) {
    throw new TypeError(`EngineRegistry requires a known engine id: ${String(id)}`);
  }
  return normalized;
}

/**
 * Owns application-facing engine adapters and their active selection.
 *
 * Registry ownership is independent from adapter ownership. This lets the
 * registry observe AVPlayer/avbridge/h265web while their teardown is still
 * coordinated by the hook, and fully own native/HLS/MPEG-TS adapters.
 */
export class EngineRegistry {
  constructor({ onDestroyError = null, onChange = null } = {}) {
    this.entries = new Map();
    this.activeId = null;
    this.destroyed = false;
    this.onDestroyError = optionalCallback(onDestroyError, "onDestroyError");
    this.onChange = optionalCallback(onChange, "onChange");
  }

  register(id, engine, { activate = false, replace = true, registryOwnsEngine = true } = {}) {
    this.assertActive();
    const engineId = normalizeId(id);
    assertPlaybackEngine(engine, { name: `${engineId} engine` });

    const current = this.entries.get(engineId);
    if (current?.engine === engine) {
      if (activate) this.activate(engineId);
      return engine;
    }

    if (current && !replace) {
      throw new Error(`EngineRegistry already contains ${engineId}`);
    }

    if (current?.registryOwnsEngine) this.dispose(engineId, current.engine);
    this.entries.set(engineId, {
      engine,
      registryOwnsEngine: registryOwnsEngine !== false,
    });
    if (activate) this.activate(engineId);
    return engine;
  }

  activate(id) {
    this.assertActive();
    const engineId = normalizeId(id);
    const entry = this.entries.get(engineId);
    if (!entry) throw new Error(`EngineRegistry cannot activate missing ${engineId}`);

    const previousId = this.activeId;
    this.activeId = engineId;
    if (previousId !== engineId) {
      safeNotify(this.onChange, {
        previousId,
        engineId,
        engine: entry.engine,
      });
    }
    return entry.engine;
  }

  registerAndActivate(id, engine, options = {}) {
    return this.register(id, engine, { ...options, activate: true });
  }

  get(id) {
    if (this.destroyed) return null;
    return this.entries.get(normalizeId(id))?.engine ?? null;
  }

  current() {
    if (this.destroyed || !this.activeId) return null;
    return this.entries.get(this.activeId)?.engine ?? null;
  }

  currentId() {
    return this.destroyed ? null : this.activeId;
  }

  has(id) {
    return !this.destroyed && this.entries.has(normalizeId(id));
  }

  deactivate(id = this.activeId) {
    if (this.destroyed || !id) return false;
    const engineId = normalizeId(id);
    if (this.activeId !== engineId) return false;
    const previousId = this.activeId;
    this.activeId = null;
    safeNotify(this.onChange, { previousId, engineId: null, engine: null });
    return true;
  }

  release(id, { destroy = null } = {}) {
    if (this.destroyed) return null;
    const engineId = normalizeId(id);
    const entry = this.entries.get(engineId);
    if (!entry) return null;

    this.entries.delete(engineId);
    if (this.activeId === engineId) this.deactivate(engineId);
    const shouldDestroy = destroy == null ? entry.registryOwnsEngine : destroy === true;
    if (shouldDestroy) this.dispose(engineId, entry.engine);
    return entry.engine;
  }

  snapshot() {
    const engines = {};
    for (const [id, entry] of this.entries) {
      engines[id] = Object.freeze({
        capabilities: playbackEngineCapabilities(entry.engine),
        destroyed: entry.engine.destroyed === true,
        registryOwnsEngine: entry.registryOwnsEngine,
      });
    }

    return Object.freeze({
      activeId: this.activeId,
      destroyed: this.destroyed,
      engines: Object.freeze(engines),
    });
  }

  destroy() {
    if (this.destroyed) return false;
    this.destroyed = true;

    const entries = [...this.entries.entries()];
    this.entries.clear();
    this.activeId = null;
    for (const [id, entry] of entries) {
      if (entry.registryOwnsEngine) this.dispose(id, entry.engine);
    }
    return true;
  }

  dispose(id, engine) {
    try {
      const result = engine.destroy();
      if (result && typeof result.catch === "function") {
        result.catch((error) => safeNotify(this.onDestroyError, error, id));
      }
    } catch (error) {
      safeNotify(this.onDestroyError, error, id);
    }
  }

  assertActive() {
    if (this.destroyed) throw new Error("EngineRegistry has been destroyed");
  }
}

export function createEngineRegistry(options = {}) {
  return new EngineRegistry(options);
}
