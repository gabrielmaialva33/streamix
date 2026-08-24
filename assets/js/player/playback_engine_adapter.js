import { assertPlaybackEngine, ENGINE_ID, normalizeEngineId } from "./engine_contract.js";

function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function normalizeEventMap(eventMap) {
  if (eventMap instanceof Map) return new Map(eventMap);
  if (eventMap && typeof eventMap === "object") {
    return new Map(Object.entries(eventMap));
  }
  return new Map();
}

/**
 * Stable application-facing contract around a concrete playback implementation.
 *
 * Concrete wrappers remain responsible for codec/library details. This adapter
 * owns identity, optional capabilities, event-name translation, snapshots, and
 * idempotent teardown so the player hook can coordinate every engine uniformly.
 */
export class PlaybackEngineAdapter {
  constructor({ id, engine, eventMap = {}, ownsEngine = true }) {
    const normalizedId = normalizeEngineId(id);
    if (normalizedId === ENGINE_ID.UNKNOWN) {
      throw new TypeError(`PlaybackEngineAdapter requires a known engine id: ${id}`);
    }

    assertPlaybackEngine(engine, { name: "PlaybackEngineAdapter" });

    this.id = normalizedId;
    this._engine = engine;
    this._eventMap = normalizeEventMap(eventMap);
    this._ownsEngine = ownsEngine !== false;
    this._destroyed = false;
    this._destroyPromise = null;
  }

  get destroyed() {
    return this._destroyed;
  }

  wraps(engine) {
    return !this._destroyed && this._engine === engine;
  }

  supports(method) {
    return !this._destroyed && typeof this._engine?.[method] === "function";
  }

  init() {
    return this._optionalCall("init");
  }

  load(source, options = {}) {
    return this._requiredCall("load", source, options);
  }

  play() {
    return this._requiredCall("play");
  }

  pause() {
    return this._softRequiredCall("pause");
  }

  stop() {
    return this._softOptionalCall("stop");
  }

  seek(seconds) {
    return this._softRequiredCall("seek", finiteNonNegative(seconds));
  }

  setVolume(volume) {
    return this._optionalCall("setVolume", volume);
  }

  getCurrentTime() {
    return finiteNonNegative(this._optionalCall("getCurrentTime"), 0);
  }

  getDuration() {
    const duration = Number(this._optionalCall("getDuration"));
    return Number.isFinite(duration) && duration >= 0 ? duration : 0;
  }

  isPlaying() {
    return this._optionalCall("isPlaying") === true;
  }

  getAudioTracks() {
    return this._optionalCall("getAudioTracks") ?? [];
  }

  getSubtitleTracks() {
    return this._optionalCall("getSubtitleTracks") ?? [];
  }

  selectAudioTrack(trackId) {
    return this._optionalCall("selectAudioTrack", trackId);
  }

  selectSubtitleTrack(trackId) {
    return this._optionalCall("selectSubtitleTrack", trackId);
  }

  loadExternalSubtitle(options) {
    return this._optionalCall("loadExternalSubtitle", options);
  }

  setSubtitleDelay(delayMs) {
    return this._optionalCall("setSubtitleDelay", delayMs);
  }

  snapshot() {
    return Object.freeze({
      engine: this.id,
      currentTime: this.getCurrentTime(),
      duration: this.getDuration(),
      paused: !this.isPlaying(),
      destroyed: this._destroyed,
    });
  }

  on(event, handler) {
    if (typeof handler !== "function") {
      throw new TypeError("Playback engine event handler must be a function");
    }

    if (!this.supports("on")) return () => {};

    const engineEvent = this._engineEvent(event);
    this._engine.on(engineEvent, handler);
    return () => this.off(event, handler);
  }

  off(event, handler) {
    if (!this.supports("off")) return;
    this._engine.off(this._engineEvent(event), handler);
  }

  destroy() {
    if (this._destroyPromise) return this._destroyPromise;

    this._destroyed = true;
    const engine = this._engine;
    let result;

    try {
      // Shared transport owners such as StreamLoader may lend an engine to the
      // hook. In that case adapter teardown only releases the reference.
      result = this._ownsEngine ? engine.destroy() : undefined;
    } catch (error) {
      result = Promise.reject(error);
    }

    this._destroyPromise = Promise.resolve(result).finally(() => {
      this._engine = null;
      this._eventMap.clear();
    });

    return this._destroyPromise;
  }

  _requiredCall(method, ...args) {
    if (this._destroyed || !this._engine) {
      throw new Error(`Playback engine ${this.id} has been destroyed`);
    }
    return this._engine[method](...args);
  }

  _softRequiredCall(method, ...args) {
    if (this._destroyed || !this._engine) return;
    return this._engine[method](...args);
  }

  _softOptionalCall(method, ...args) {
    if (this._destroyed || !this._engine) return undefined;
    if (typeof this._engine[method] !== "function") return undefined;
    return this._engine[method](...args);
  }

  _optionalCall(method, ...args) {
    if (!this.supports(method)) return undefined;
    return this._engine[method](...args);
  }

  _engineEvent(event) {
    return this._eventMap.get(event) ?? event;
  }
}

export function createPlaybackEngineAdapter(options) {
  return new PlaybackEngineAdapter(options);
}
