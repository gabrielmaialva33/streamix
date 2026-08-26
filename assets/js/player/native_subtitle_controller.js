import { hasSubtitleInLanguage } from "./track_metadata.js";

const DEFAULT_RELOAD_DELAY_MS = 150;

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`NativeSubtitleController requires ${name}()`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`NativeSubtitleController ${name} must be a function`);
  }

  return value;
}

function assertVideo(video) {
  if (!video || typeof video.appendChild !== "function") {
    throw new TypeError("NativeSubtitleController requires a video element");
  }

  return video;
}

function safeNotify(callback, ...args) {
  if (!callback) return;

  try {
    const result = callback(...args);
    if (result && typeof result.then === "function") {
      Promise.resolve(result).catch(() => {});
    }
  } catch {
    // Product callbacks and diagnostics must never break subtitle lifecycle.
  }
}

function finiteOffset(value) {
  const offset = Number(value);
  return Number.isFinite(offset) ? Math.trunc(offset) : 0;
}

function normalizeSelection(value) {
  if (value == null || typeof value === "boolean") return null;
  if (typeof value === "string" && value.trim() === "") return null;

  const selection = Number(value);
  return Number.isInteger(selection) && (selection === -1 || selection === 0) ? selection : null;
}

function normalizeReloadDelay(value) {
  const delay = Number(value);
  return Number.isFinite(delay) && delay >= 0 ? Math.trunc(delay) : DEFAULT_RELOAD_DELAY_MS;
}

function createDefaultTrackElement() {
  const createElement = globalThis.document?.createElement;
  if (typeof createElement !== "function") {
    throw new TypeError("NativeSubtitleController requires createTrackElement()");
  }

  return createElement.call(globalThis.document, "track");
}

function once(callback) {
  if (typeof callback !== "function") return null;

  let called = false;
  return () => {
    if (called) return;
    called = true;
    callback();
  };
}

function normalizeSourceLease(value) {
  if (typeof value === "string") {
    const source = value.trim();
    return source ? { release: null, source } : null;
  }

  if (!value || typeof value !== "object") return null;

  const source = String(value.source ?? value.url ?? "").trim();
  if (!source) return null;

  return {
    release: once(value.release),
    source,
  };
}

function removeTrackElement(video, trackElement) {
  if (!trackElement) return;

  if (typeof trackElement.remove === "function") {
    trackElement.remove();
    return;
  }

  if (trackElement.parentNode === video && typeof video.removeChild === "function") {
    video.removeChild(trackElement);
  }
}

function setTrackMode(trackElement, mode) {
  if (trackElement?.track && "mode" in trackElement.track) {
    trackElement.track.mode = mode;
  }
}

function readTrackMode(trackElement) {
  const mode = trackElement?.track?.mode;
  return typeof mode === "string" ? mode : "disabled";
}

function nativeTrackMetadata(video) {
  try {
    return Array.from(video.textTracks || []).map((track) => ({
      label: track?.label,
      language: track?.language,
    }));
  } catch {
    return [];
  }
}

function immutableTrackSnapshot(trackElement) {
  if (!trackElement) return Object.freeze([]);

  const active = readTrackMode(trackElement) === "showing";
  return Object.freeze([
    Object.freeze({
      active,
      id: 0,
      index: 0,
      label: String(trackElement.label || ""),
      language: String(trackElement.srclang || trackElement.track?.language || ""),
      selected: active,
      selectionId: 0,
    }),
  ]);
}

export class NativeSubtitleController {
  constructor({
    video,
    resolveSource,
    createTrackElement = createDefaultTrackElement,
    isSessionCurrent = () => true,
    schedule = globalThis.setTimeout?.bind(globalThis),
    cancelSchedule = globalThis.clearTimeout?.bind(globalThis),
    reloadDelayMs = DEFAULT_RELOAD_DELAY_MS,
    onError = null,
  } = {}) {
    this._video = assertVideo(video);
    this._resolveSource = requiredCallback(resolveSource, "resolveSource");
    this._createTrackElement = requiredCallback(createTrackElement, "createTrackElement");
    this._isSessionCurrent = requiredCallback(isSessionCurrent, "isSessionCurrent");
    this._schedule = requiredCallback(schedule, "schedule");
    this._cancelSchedule = requiredCallback(cancelSchedule, "cancelSchedule");
    this._onError = optionalCallback(onError, "onError");
    this._reloadDelayMs = normalizeReloadDelay(reloadDelayMs);

    this._destroyed = false;
    this._revision = 0;
    this._trackElement = null;
    this._sourceLease = null;
    this._selection = -1;
    this._sessionId = null;
    this._reloadTimer = null;
    this._reloadRequest = null;
    this._reloadPromise = null;
    this._reloadSequence = 0;
  }

  get active() {
    return this._trackElement != null;
  }

  get destroyed() {
    return this._destroyed;
  }

  async load({
    sessionId,
    force = false,
    language = "pt-BR",
    label = "Português (auto)",
    offsetMs = 0,
  } = {}) {
    if (!this._canOperate(sessionId)) return false;
    if (!force && this._hasTrackInLanguage(language)) return false;

    const revision = ++this._revision;
    let lease = null;
    let trackElement = null;

    try {
      lease = normalizeSourceLease(
        await this._resolveSource({
          force: force === true,
          language,
          offsetMs: finiteOffset(offsetMs),
          sessionId,
        }),
      );
      if (!lease) return false;

      if (!this._isCurrent(revision, sessionId)) {
        this._releaseLease(lease);
        return false;
      }

      trackElement = this._createTrackElement();
      if (!trackElement || typeof trackElement !== "object") {
        throw new TypeError("createTrackElement() must return a track element");
      }

      trackElement.kind = "subtitles";
      trackElement.label = String(label || "");
      trackElement.srclang = String(language || "");
      trackElement.src = lease.source;
      this._video.appendChild(trackElement);

      if (!this._isCurrent(revision, sessionId)) {
        removeTrackElement(this._video, trackElement);
        this._releaseLease(lease);
        return false;
      }

      this._replaceTrack(trackElement, lease);
      this._sessionId = sessionId;
      this._selection = -1;
      setTrackMode(trackElement, "disabled");
      return this.snapshot();
    } catch (error) {
      if (trackElement && trackElement !== this._trackElement) {
        removeTrackElement(this._video, trackElement);
      }
      if (lease && lease !== this._sourceLease) {
        this._releaseLease(lease);
      }
      this._report("load", error);
      return false;
    }
  }

  select(trackIndex) {
    if (this._destroyed || !this._trackElement) return false;

    const selection = normalizeSelection(trackIndex);
    if (selection == null) return false;

    setTrackMode(this._trackElement, selection === -1 ? "disabled" : "showing");
    this._selection = selection;
    return selection;
  }

  reload(options = {}) {
    if (!this._canOperate(options.sessionId)) return false;
    if (this._reloadPromise) return this._reloadPromise;

    this._clearTrack();
    const promise = Promise.resolve(this.load({ ...options, force: true }));
    const trackedPromise = promise.finally(() => {
      if (this._reloadPromise === trackedPromise) {
        this._reloadPromise = null;
      }
      if (this._reloadRequest && this._reloadTimer == null && !this._destroyed) {
        this._scheduleStoredReload();
      }
    });

    this._reloadPromise = trackedPromise;
    return trackedPromise;
  }

  scheduleReload(options = {}, onComplete = null) {
    if (this._destroyed || (!this._trackElement && !this._reloadPromise)) return false;

    const completion = optionalCallback(onComplete, "onComplete");
    this._revision += 1;
    this._reloadSequence += 1;
    this._cancelReloadTimer();
    this._reloadRequest = {
      completion,
      options: { ...options, force: true },
      sequence: this._reloadSequence,
    };
    this._scheduleStoredReload();
    return true;
  }

  snapshot() {
    return Object.freeze({
      active: this.active,
      destroyed: this._destroyed,
      reloadScheduled: this._reloadTimer != null,
      reloading: this._reloadPromise != null,
      revision: this._revision,
      selectedTrack: this._trackElement ? this._selection : -1,
      sessionId: this._sessionId,
      tracks: immutableTrackSnapshot(this._trackElement),
    });
  }

  reset() {
    if (this._destroyed) return false;

    const changed =
      this._trackElement != null ||
      this._sourceLease != null ||
      this._reloadTimer != null ||
      this._reloadPromise != null ||
      this._reloadRequest != null;

    this._resetState();
    return changed;
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this._resetState();
    return true;
  }

  _canOperate(sessionId) {
    return !this._destroyed && this._sessionIsCurrent(sessionId);
  }

  _sessionIsCurrent(sessionId) {
    try {
      return this._isSessionCurrent(sessionId) !== false;
    } catch (error) {
      this._report("session_guard", error);
      return false;
    }
  }

  _isCurrent(revision, sessionId) {
    return !this._destroyed && this._revision === revision && this._sessionIsCurrent(sessionId);
  }

  _hasTrackInLanguage(language) {
    if (
      this._trackElement &&
      hasSubtitleInLanguage(
        [
          {
            label: this._trackElement.label,
            language: this._trackElement.srclang,
          },
        ],
        language,
      )
    ) {
      return true;
    }

    return hasSubtitleInLanguage(nativeTrackMetadata(this._video), language);
  }

  _replaceTrack(trackElement, lease) {
    this._clearTrack();
    this._trackElement = trackElement;
    this._sourceLease = lease;
  }

  _clearTrack() {
    const trackElement = this._trackElement;
    const lease = this._sourceLease;

    this._trackElement = null;
    this._sourceLease = null;
    this._selection = -1;
    this._sessionId = null;

    removeTrackElement(this._video, trackElement);
    this._releaseLease(lease);
  }

  _releaseLease(lease) {
    if (!lease?.release) return;

    try {
      lease.release();
    } catch (error) {
      this._report("release_source", error);
    }
  }

  _scheduleStoredReload() {
    if (this._destroyed || !this._reloadRequest || this._reloadTimer != null) return;

    this._reloadTimer = this._schedule(() => {
      this._reloadTimer = null;
      return this._drainReloadRequest();
    }, this._reloadDelayMs);
  }

  async _drainReloadRequest() {
    if (this._destroyed || !this._reloadRequest) return;

    if (this._reloadPromise) {
      this._scheduleStoredReload();
      return;
    }

    const request = this._reloadRequest;
    this._reloadRequest = null;
    const result = await this.reload(request.options);
    if (request.sequence === this._reloadSequence && !this._reloadRequest && !this._destroyed) {
      safeNotify(request.completion, result);
    }
  }

  _cancelReloadTimer() {
    if (this._reloadTimer == null) return;

    this._cancelSchedule(this._reloadTimer);
    this._reloadTimer = null;
  }

  _resetState() {
    this._revision += 1;
    this._reloadSequence += 1;
    this._cancelReloadTimer();
    this._reloadRequest = null;
    this._reloadPromise = null;
    this._clearTrack();
  }

  _report(operation, error) {
    safeNotify(this._onError, operation, error);
  }
}

export function createNativeSubtitleController(options) {
  return new NativeSubtitleController(options);
}
