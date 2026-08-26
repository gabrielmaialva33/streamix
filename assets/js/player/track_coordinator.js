import { playbackEngineCapabilities } from "./engine_contract.js";

const EMPTY_TRACKS = Object.freeze([]);

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

function isPromiseLike(value) {
  return value != null && typeof value.then === "function";
}

function sameIdentifier(left, right) {
  return (
    Object.is(left, right) || (left != null && right != null && String(left) === String(right))
  );
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
  if (!Array.isArray(tracks)) return EMPTY_TRACKS;
  return Object.freeze(tracks.map((track, index) => normalizeTrack(track, index, kind)));
}

function trackSelectionId(track, fallback) {
  return track?.raw?.selectionId ?? track?.id ?? fallback;
}

/**
 * Normalizes optional audio/subtitle capabilities across playback engines.
 * Engine-specific policy remains in the engine or its owner; this coordinator
 * owns async discovery, cache invalidation, and one safe application-facing
 * selection surface.
 */
export class TrackCoordinator {
  constructor({ getEngine, onChange = null, onError = null } = {}) {
    this.getEngine = requiredCallback(getEngine, "getEngine");
    this.onChange = optionalCallback(onChange, "onChange");
    this.onError = optionalCallback(onError, "onError");
    this._engine = null;
    this._audioTracks = EMPTY_TRACKS;
    this._subtitleTracks = EMPTY_TRACKS;
    this._refreshRevisions = { audio: 0, subtitle: 0 };
    this._selectionRevisions = { audio: 0, subtitle: 0 };
  }

  capabilities() {
    const engine = this._syncEngine();
    if (!engine) return Object.freeze({});
    return playbackEngineCapabilities(engine);
  }

  audioTracks() {
    this._syncEngine();
    return this._audioTracks;
  }

  subtitleTracks() {
    this._syncEngine();
    return this._subtitleTracks;
  }

  refreshAudioTracks() {
    return this._refreshTracks("getAudioTracks", "audio");
  }

  refreshSubtitleTracks() {
    return this._refreshTracks("getSubtitleTracks", "subtitle");
  }

  selectAudioTrack(trackId) {
    return this._select("selectAudioTrack", trackId, "audio");
  }

  selectSubtitleTrack(trackId) {
    return this._select("selectSubtitleTrack", trackId, "subtitle");
  }

  loadExternalSubtitle(options) {
    return this._invokeCommand("loadExternalSubtitle", [options], false);
  }

  setSubtitleDelay(delayMs) {
    const delay = Number(delayMs);
    if (!Number.isFinite(delay)) return false;
    return this._invokeCommand("setSubtitleDelay", [delay], false);
  }

  snapshot() {
    this._syncEngine();
    return Object.freeze({
      capabilities: this.capabilities(),
      audioTracks: this._audioTracks,
      subtitleTracks: this._subtitleTracks,
    });
  }

  _refreshTracks(method, kind) {
    const engine = this._syncEngine();
    const revision = ++this._refreshRevisions[kind];

    if (!engine || typeof engine[method] !== "function") {
      return this._setTracks(kind, EMPTY_TRACKS);
    }

    let result;
    try {
      result = engine[method]();
    } catch (error) {
      safeNotify(this.onError, error, method);
      return this._commitRefresh(kind, engine, revision, EMPTY_TRACKS);
    }

    if (!isPromiseLike(result)) {
      return this._commitRefresh(kind, engine, revision, result);
    }

    return Promise.resolve(result).then(
      (tracks) => this._commitRefresh(kind, engine, revision, tracks),
      (error) => {
        safeNotify(this.onError, error, method);
        return this._commitRefresh(kind, engine, revision, EMPTY_TRACKS);
      },
    );
  }

  _commitRefresh(kind, engine, revision, tracks) {
    if (this._syncEngine() !== engine || this._refreshRevisions[kind] !== revision) {
      return this._tracksFor(kind);
    }

    return this._setTracks(kind, normalizeTracks(tracks, kind));
  }

  _select(method, trackId, kind) {
    const engine = this._syncEngine();
    if (!engine || typeof engine[method] !== "function") return false;

    const selectionId = this._resolveSelectionId(kind, trackId);
    const revision = ++this._selectionRevisions[kind];
    let result;

    try {
      result = engine[method](selectionId);
    } catch (error) {
      safeNotify(this.onError, error, method);
      return false;
    }

    if (!isPromiseLike(result)) {
      return this._completeSelection(kind, trackId, selectionId, result, engine, revision);
    }

    return Promise.resolve(result).then(
      (output) => this._completeSelection(kind, trackId, selectionId, output, engine, revision),
      (error) => {
        safeNotify(this.onError, error, method);
        throw error;
      },
    );
  }

  _completeSelection(kind, trackId, selectionId, result, engine, revision) {
    if (result === false || result == null) return false;
    if (this._syncEngine() !== engine || this._selectionRevisions[kind] !== revision) {
      return result;
    }

    this._markActive(kind, trackId, selectionId);
    safeNotify(this.onChange, { kind, trackId, selectionId, result });
    return result;
  }

  _invokeCommand(method, args, fallback) {
    const engine = this._syncEngine();
    if (!engine || typeof engine[method] !== "function") return fallback;

    let result;
    try {
      result = engine[method](...args);
    } catch (error) {
      safeNotify(this.onError, error, method);
      return fallback;
    }

    if (!isPromiseLike(result)) return result;

    return Promise.resolve(result).catch((error) => {
      safeNotify(this.onError, error, method);
      throw error;
    });
  }

  _resolveSelectionId(kind, trackId) {
    if (kind === "subtitle" && Number(trackId) === -1) return -1;

    const track = this._tracksFor(kind).find(
      (candidate) =>
        sameIdentifier(candidate.index, trackId) || sameIdentifier(candidate.id, trackId),
    );

    return trackSelectionId(track, trackId);
  }

  _markActive(kind, trackId, selectionId) {
    const tracks = this._tracksFor(kind);
    if (tracks.length === 0) return;

    const next = Object.freeze(
      tracks.map((track) => {
        const active =
          !(kind === "subtitle" && Number(trackId) === -1) &&
          (sameIdentifier(track.index, trackId) ||
            sameIdentifier(track.id, trackId) ||
            sameIdentifier(trackSelectionId(track, null), selectionId));

        return Object.freeze({ ...track, active });
      }),
    );

    this._setTracks(kind, next);
  }

  _syncEngine() {
    let engine = null;

    try {
      engine = this.getEngine() ?? null;
    } catch (error) {
      safeNotify(this.onError, error, "getEngine");
    }

    if (engine !== this._engine) {
      this._engine = engine;
      this._audioTracks = EMPTY_TRACKS;
      this._subtitleTracks = EMPTY_TRACKS;
      this._refreshRevisions.audio += 1;
      this._refreshRevisions.subtitle += 1;
      this._selectionRevisions.audio += 1;
      this._selectionRevisions.subtitle += 1;
    }

    return engine;
  }

  _tracksFor(kind) {
    return kind === "audio" ? this._audioTracks : this._subtitleTracks;
  }

  _setTracks(kind, tracks) {
    if (kind === "audio") this._audioTracks = tracks;
    else this._subtitleTracks = tracks;
    return tracks;
  }
}

export function createTrackCoordinator(options) {
  return new TrackCoordinator(options);
}
