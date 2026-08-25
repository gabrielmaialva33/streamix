import { playbackEngineCapabilities } from "./engine_contract.js";

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`TrackCoordinator ${name} must be a function`);
  }
  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`TrackCoordinator ${name} must be a function`);
  }
  return value;
}

function safeNotify(callback, ...args) {
  if (!callback) return;
  try {
    callback(...args);
  } catch {
    // UI and telemetry observers must not break track selection.
  }
}

function normalizeTrack(track, index, kind) {
  const candidate = track && typeof track === "object" ? track : {};
  const id = candidate.id ?? candidate.index ?? index;
  const language = candidate.language ?? candidate.lang ?? candidate.languageCode ?? null;
  const label =
    candidate.label ??
    candidate.name ??
    candidate.title ??
    (language ? String(language) : `${kind} ${index + 1}`);

  return Object.freeze({
    id,
    index: Number.isInteger(candidate.index) ? candidate.index : index,
    kind,
    label: String(label),
    language: language == null ? null : String(language),
    active: candidate.active === true || candidate.selected === true,
    default: candidate.default === true || candidate.isDefault === true,
    forced: candidate.forced === true || candidate.isForced === true,
    raw: candidate,
  });
}

function normalizeTracks(tracks, kind) {
  if (!Array.isArray(tracks)) return Object.freeze([]);
  return Object.freeze(tracks.map((track, index) => normalizeTrack(track, index, kind)));
}

/**
 * Normalizes optional audio/subtitle capabilities across playback engines.
 * Engine-specific policy remains in the engine or its owner; this coordinator
 * only provides one safe application-facing surface.
 */
export class TrackCoordinator {
  constructor({ getEngine, onChange = null, onError = null } = {}) {
    this.getEngine = requiredCallback(getEngine, "getEngine");
    this.onChange = optionalCallback(onChange, "onChange");
    this.onError = optionalCallback(onError, "onError");
  }

  capabilities() {
    const engine = this.getEngine();
    if (!engine) return Object.freeze({});
    return playbackEngineCapabilities(engine);
  }

  audioTracks() {
    return normalizeTracks(this.invoke("getAudioTracks", [], []), "audio");
  }

  subtitleTracks() {
    return normalizeTracks(this.invoke("getSubtitleTracks", [], []), "subtitle");
  }

  selectAudioTrack(trackId) {
    return this.select("selectAudioTrack", trackId, "audio");
  }

  selectSubtitleTrack(trackId) {
    return this.select("selectSubtitleTrack", trackId, "subtitle");
  }

  loadExternalSubtitle(options) {
    return this.invoke("loadExternalSubtitle", [options], false);
  }

  setSubtitleDelay(delayMs) {
    const delay = Number(delayMs);
    if (!Number.isFinite(delay)) return false;
    return this.invoke("setSubtitleDelay", [delay], false);
  }

  snapshot() {
    return Object.freeze({
      capabilities: this.capabilities(),
      audioTracks: this.audioTracks(),
      subtitleTracks: this.subtitleTracks(),
    });
  }

  select(method, trackId, kind) {
    const result = this.invoke(method, [trackId], false);
    if (result === false || result == null) return false;
    safeNotify(this.onChange, { kind, trackId, result });
    return result;
  }

  invoke(method, args, fallback) {
    const engine = this.getEngine();
    if (!engine || typeof engine[method] !== "function") return fallback;

    try {
      return engine[method](...args);
    } catch (error) {
      safeNotify(this.onError, error, method);
      return fallback;
    }
  }
}

export function createTrackCoordinator(options) {
  return new TrackCoordinator(options);
}
