function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlayerTrackController requires ${name}()`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`PlayerTrackController ${name} must be a function`);
  }

  return value;
}

function safeNotify(callback, ...args) {
  if (!callback) return;

  try {
    callback(...args);
  } catch {
    // Track diagnostics must never replace the original operation result.
  }
}

function isPromiseLike(value) {
  return value != null && typeof value.then === "function";
}

function finiteOffset(value) {
  const offset = Number(value);
  return Number.isFinite(offset) ? offset : 0;
}

const OPERATION = Object.freeze({
  AUDIO_TRACK: "audio_track",
  SUBTITLE_TRACK: "subtitle_track",
  SUBTITLE_OFFSET: "subtitle_offset",
  REFRESH_AUDIO: "refresh_audio",
  REFRESH_SUBTITLES: "refresh_subtitles",
});

export class PlayerTrackController {
  constructor({
    refreshAudioTracks,
    refreshSubtitleTracks,
    selectAudioTrack,
    selectSubtitleTrack,
    setSubtitleOffset,
    onError = null,
  }) {
    this._operations = Object.freeze({
      refreshAudioTracks: requiredCallback(refreshAudioTracks, "refreshAudioTracks"),
      refreshSubtitleTracks: requiredCallback(
        refreshSubtitleTracks,
        "refreshSubtitleTracks",
      ),
      selectAudioTrack: requiredCallback(selectAudioTrack, "selectAudioTrack"),
      selectSubtitleTrack: requiredCallback(
        selectSubtitleTrack,
        "selectSubtitleTrack",
      ),
      setSubtitleOffset: requiredCallback(setSubtitleOffset, "setSubtitleOffset"),
    });
    this._onError = optionalCallback(onError, "onError");
    this._destroyed = false;
    this._revision = 0;
    this._desired = {
      audioTrack: null,
      subtitleTrack: null,
      subtitleOffset: 0,
    };
    this._applied = {
      audioTrack: null,
      subtitleTrack: null,
      subtitleOffset: 0,
    };
    this._pending = new Map();
  }

  get destroyed() {
    return this._destroyed;
  }

  refreshAudioTracks() {
    return this._runRefresh(
      OPERATION.REFRESH_AUDIO,
      this._operations.refreshAudioTracks,
    );
  }

  refreshSubtitleTracks() {
    return this._runRefresh(
      OPERATION.REFRESH_SUBTITLES,
      this._operations.refreshSubtitleTracks,
    );
  }

  selectAudioTrack(trackIndex) {
    return this._runSelection(
      OPERATION.AUDIO_TRACK,
      "audioTrack",
      trackIndex,
      this._operations.selectAudioTrack,
    );
  }

  selectSubtitleTrack(trackIndex) {
    return this._runSelection(
      OPERATION.SUBTITLE_TRACK,
      "subtitleTrack",
      trackIndex,
      this._operations.selectSubtitleTrack,
    );
  }

  setSubtitleOffset(offsetMs) {
    const normalized = finiteOffset(offsetMs);

    return this._runSelection(
      OPERATION.SUBTITLE_OFFSET,
      "subtitleOffset",
      normalized,
      this._operations.setSubtitleOffset,
    );
  }

  snapshot() {
    return Object.freeze({
      destroyed: this._destroyed,
      revision: this._revision,
      desired: Object.freeze({ ...this._desired }),
      applied: Object.freeze({ ...this._applied }),
      pending: Object.freeze({
        audioTrack: this._pending.has(OPERATION.AUDIO_TRACK),
        subtitleTrack: this._pending.has(OPERATION.SUBTITLE_TRACK),
        subtitleOffset: this._pending.has(OPERATION.SUBTITLE_OFFSET),
        refreshAudio: this._pending.has(OPERATION.REFRESH_AUDIO),
        refreshSubtitles: this._pending.has(OPERATION.REFRESH_SUBTITLES),
      }),
    });
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this._revision += 1;
    this._pending.clear();
    return true;
  }

  _runRefresh(operationName, operation) {
    if (this._destroyed) return undefined;

    const current = this._pending.get(operationName);
    if (current) return current.result;

    return this._run(operationName, operation, undefined, null);
  }

  _runSelection(operationName, stateKey, value, operation) {
    if (this._destroyed) return undefined;

    const current = this._pending.get(operationName);
    if (current && Object.is(current.value, value)) return current.result;

    this._desired[stateKey] = value;
    return this._run(operationName, operation, value, stateKey);
  }

  _run(operationName, operation, value, stateKey) {
    const revision = ++this._revision;
    let result;

    try {
      result = stateKey == null ? operation() : operation(value);
    } catch (error) {
      this._report(operationName, error);
      throw error;
    }

    if (!isPromiseLike(result)) {
      if (stateKey != null && !this._destroyed && revision === this._revision) {
        this._applied[stateKey] = value;
      }
      return result;
    }

    const pending = {
      revision,
      value,
      result: null,
    };

    const promise = Promise.resolve(result).then(
      (output) => {
        if (!this._destroyed && revision === this._revision && stateKey != null) {
          this._applied[stateKey] = value;
        }
        this._clearPending(operationName, pending);
        return output;
      },
      (error) => {
        this._clearPending(operationName, pending);
        this._report(operationName, error);
        throw error;
      },
    );

    pending.result = promise;
    this._pending.set(operationName, pending);
    return promise;
  }

  _clearPending(operationName, pending) {
    if (this._pending.get(operationName) === pending) {
      this._pending.delete(operationName);
    }
  }

  _report(operationName, error) {
    safeNotify(this._onError, operationName, error);
  }
}

export function createPlayerTrackController(options) {
  return new PlayerTrackController(options);
}
