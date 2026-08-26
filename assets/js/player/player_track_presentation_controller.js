import { findPortugueseTrack, formatTrackLabel } from "./track_metadata.js";

const MAX_SUBTITLE_OFFSET_MS = 600_000;
const SUBTITLE_DISABLED_TRACK = Object.freeze({ index: -1, label: "Desativado" });

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlayerTrackPresentationController requires ${name}()`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`PlayerTrackPresentationController ${name} must be a function`);
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
    // Rendering, persistence and diagnostics must not break playback commands.
  }
}

function immutableTracks(tracks) {
  if (!Array.isArray(tracks)) return Object.freeze([]);

  return Object.freeze(
    tracks.map((track, index) =>
      Object.freeze({
        ...track,
        index: Number.isInteger(track?.index) ? track.index : index,
      }),
    ),
  );
}

function finiteTrackIndex(value, fallback = -1) {
  if (value == null || typeof value === "boolean") return fallback;
  if (typeof value === "string" && value.trim() === "") return fallback;

  const index = Number(value);
  return Number.isInteger(index) ? index : fallback;
}

function validTrackIndex(value, tracks, { allowDisabled = false } = {}) {
  const index = finiteTrackIndex(value);
  if (allowDisabled && index === -1) return true;
  return index >= 0 && index < tracks.length;
}

function normalizeSubtitleOffset(value) {
  const offset = Number(value);
  if (!Number.isFinite(offset)) return null;

  return Math.max(-MAX_SUBTITLE_OFFSET_MS, Math.min(MAX_SUBTITLE_OFFSET_MS, Math.trunc(offset)));
}

function subtitleOffsetLabel(offsetMs) {
  const seconds = offsetMs / 1_000;
  if (seconds === 0) return "0.0s";
  return `${seconds > 0 ? "+" : ""}${seconds.toFixed(1)}s`;
}

function audioSelectionLabel(track, trackIndex) {
  if (!track) return `Faixa ${trackIndex + 1}`;
  return formatTrackLabel(track);
}

function subtitleSelectionLabel(track, trackIndex) {
  if (trackIndex === -1) return SUBTITLE_DISABLED_TRACK.label;

  return track?.label || track?.name || track?.lang || track?.language || `Faixa ${trackIndex}`;
}

function nativeTracks(snapshot) {
  if (!Array.isArray(snapshot?.tracks)) return Object.freeze([]);

  return immutableTracks(
    snapshot.tracks.map((track, index) => ({
      id: track?.id ?? index,
      index: Number.isInteger(track?.index) ? track.index : index,
      label: String(track?.label ?? ""),
      language: String(track?.language ?? ""),
      selectionId: track?.selectionId ?? track?.id ?? index,
    })),
  );
}

function probedAudioTracks(tracks) {
  if (!Array.isArray(tracks) || tracks.length <= 1) return Object.freeze([]);

  return immutableTracks(
    tracks.map((track, index) => ({
      id: track?.index,
      index,
      label: formatTrackLabel({
        channels: track?.channels,
        codec: track?.codec,
        index,
        label: track?.title,
        language: track?.language,
      }),
      language: track?.language || "",
    })),
  );
}

function probedSubtitleTracks(tracks) {
  if (!Array.isArray(tracks) || tracks.length === 0) return Object.freeze([]);

  return immutableTracks(
    tracks.map((track, index) => ({
      id: track?.index,
      index,
      label: formatTrackLabel({
        codec: track?.codec,
        index,
        label: track?.title,
        language: track?.language,
      }),
      language: track?.language || "",
    })),
  );
}

export class PlayerTrackPresentationController {
  constructor({
    emit,
    getContentId,
    isSessionCurrent = () => true,
    onError = null,
    onStateChange = null,
    renderAudioOptions,
    renderSubtitleOptions,
    renderSubtitleOffset,
    saveAudioPreference,
    saveSubtitlePreference,
    initialState = {},
  } = {}) {
    this._emit = requiredCallback(emit, "emit");
    this._getContentId = requiredCallback(getContentId, "getContentId");
    this._isSessionCurrent = requiredCallback(isSessionCurrent, "isSessionCurrent");
    this._renderAudioOptions = requiredCallback(renderAudioOptions, "renderAudioOptions");
    this._renderSubtitleOptions = requiredCallback(renderSubtitleOptions, "renderSubtitleOptions");
    this._renderSubtitleOffset = requiredCallback(renderSubtitleOffset, "renderSubtitleOffset");
    this._saveAudioPreference = requiredCallback(saveAudioPreference, "saveAudioPreference");
    this._saveSubtitlePreference = requiredCallback(
      saveSubtitlePreference,
      "saveSubtitlePreference",
    );
    this._onError = optionalCallback(onError, "onError");
    this._onStateChange = optionalCallback(onStateChange, "onStateChange");

    this._destroyed = false;
    this._revision = 0;
    this._audioTracksRevision = 0;
    this._subtitleTracksRevision = 0;
    this._audioTracks = immutableTracks(initialState.audioTracks);
    this._probedAudioTracks = Object.freeze([]);
    this._probedSubtitleTracks = Object.freeze([]);
    this._probedSelectedAudioTrack = 0;
    this._probedSelectedSubtitleTrack = -1;
    this._subtitleTracks = immutableTracks(initialState.subtitleTracks);
    this._selectedAudioTrack = finiteTrackIndex(initialState.selectedAudioTrack, 0);
    this._selectedSubtitleTrack = finiteTrackIndex(initialState.selectedSubtitleTrack, -1);
    this._subtitleOffsetMs = normalizeSubtitleOffset(initialState.subtitleOffsetMs) ?? 0;
  }

  get destroyed() {
    return this._destroyed;
  }

  snapshot() {
    return Object.freeze({
      audioTracks: this._audioTracks,
      destroyed: this._destroyed,
      probedAudioTracks: this._probedAudioTracks,
      probedSelectedAudioTrack: this._probedSelectedAudioTrack,
      probedSelectedSubtitleTrack: this._probedSelectedSubtitleTrack,
      probedSubtitleTracks: this._probedSubtitleTracks,
      revision: this._revision,
      selectedAudioTrack: this._selectedAudioTrack,
      selectedSubtitleTrack: this._selectedSubtitleTrack,
      subtitleOffsetMs: this._subtitleOffsetMs,
      subtitleTracks: this._subtitleTracks,
    });
  }

  presentProbedTracks({
    audioTracks,
    onAudioSelect,
    onSubtitleSelect,
    sessionId,
    subtitleTracks,
  } = {}) {
    if (!this._canPresent(sessionId)) return false;

    this._audioTracksRevision += 1;
    this._subtitleTracksRevision += 1;
    this._probedAudioTracks = probedAudioTracks(audioTracks);
    this._probedSubtitleTracks = probedSubtitleTracks(subtitleTracks);
    this._probedSelectedAudioTrack =
      this._probedAudioTracks.length > 0 ? findPortugueseTrack(this._probedAudioTracks) : 0;
    this._probedSelectedSubtitleTrack = -1;
    this._revision += 1;
    this._notifyState();

    if (this._probedAudioTracks.length > 0) {
      safeNotify(
        this._renderAudioOptions,
        this._probedAudioTracks,
        this._probedSelectedAudioTrack,
        onAudioSelect,
      );
      safeNotify(this._emit, "audio_tracks_available", {
        current: this._probedSelectedAudioTrack,
        tracks: this._probedAudioTracks,
      });
    }

    if (this._probedSubtitleTracks.length > 0) {
      safeNotify(
        this._renderSubtitleOptions,
        this._probedSubtitleTracks,
        this._probedSelectedSubtitleTrack,
        onSubtitleSelect,
      );
      safeNotify(this._emit, "subtitle_tracks_available", {
        current: this._probedSelectedSubtitleTrack,
        tracks: [SUBTITLE_DISABLED_TRACK, ...this._probedSubtitleTracks],
      });
    }

    return Object.freeze({
      audioTracks: this._probedAudioTracks,
      selectedAudioTrack: this._probedSelectedAudioTrack,
      selectedSubtitleTrack: this._probedSelectedSubtitleTrack,
      subtitleTracks: this._probedSubtitleTracks,
    });
  }

  async presentAudioTracks({
    activeTrack = 0,
    preferredTrack = null,
    selectTrack,
    sessionId,
    tracks,
  } = {}) {
    if (!this._canPresent(sessionId)) return false;

    const tracksRevision = ++this._audioTracksRevision;
    this._audioTracks = immutableTracks(tracks);
    this._revision += 1;
    this._notifyState();

    if (this._audioTracks.length === 0) {
      this._selectedAudioTrack = 0;
      this._notifyState();
      safeNotify(this._renderAudioOptions, this._audioTracks, 0, selectTrack);
      return this._audioTracks;
    }

    const target = this._resolveAudioTarget({ activeTrack, preferredTrack });
    const selectionResult = await this._applySelection(selectTrack, target, "audio_selection");
    if (!this._audioTracksAreCurrent(tracksRevision, sessionId)) return false;

    if (selectionResult === false || selectionResult == null) {
      const fallback = validTrackIndex(activeTrack, this._audioTracks)
        ? finiteTrackIndex(activeTrack, 0)
        : 0;
      this._selectedAudioTrack = fallback;
      this._notifyState();
    }

    safeNotify(this._renderAudioOptions, this._audioTracks, this._selectedAudioTrack, selectTrack);
    safeNotify(this._emit, "audio_tracks_available", {
      current: this._selectedAudioTrack,
      tracks: this._audioTracks,
    });

    return this._audioTracks;
  }

  presentAudioSelection(trackIndex, { sessionId } = {}) {
    if (!this._canPresent(sessionId)) return false;

    const index = finiteTrackIndex(trackIndex);
    if (!validTrackIndex(index, this._audioTracks)) return false;

    this._selectedAudioTrack = index;
    this._revision += 1;
    this._notifyState();

    safeNotify(this._saveAudioPreference, index, this._getContentId());
    safeNotify(this._emit, "audio_track_changed", {
      label: audioSelectionLabel(this._audioTracks[index], index),
      track: index,
    });

    return index;
  }

  async presentSubtitleTracks({
    activeTrack = -1,
    preferredTrack = null,
    selectTrack,
    sessionId,
    subtitlesEnabled = true,
    tracks,
  } = {}) {
    if (!this._canPresent(sessionId)) return false;

    const tracksRevision = ++this._subtitleTracksRevision;
    this._subtitleTracks = immutableTracks(tracks);
    this._revision += 1;
    this._notifyState();

    const target = this._resolveSubtitleTarget({
      activeTrack,
      preferredTrack,
      subtitlesEnabled,
    });
    const selectionResult = await this._applySelection(selectTrack, target, "subtitle_selection");
    if (!this._subtitleTracksAreCurrent(tracksRevision, sessionId)) return false;

    if (selectionResult === false || selectionResult == null) {
      this._selectedSubtitleTrack = validTrackIndex(activeTrack, this._subtitleTracks, {
        allowDisabled: true,
      })
        ? finiteTrackIndex(activeTrack)
        : -1;
      this._notifyState();
    }

    safeNotify(
      this._renderSubtitleOptions,
      this._subtitleTracks,
      this._selectedSubtitleTrack,
      selectTrack,
    );
    safeNotify(this._emit, "subtitle_tracks_available", {
      current: this._selectedSubtitleTrack,
      tracks: [SUBTITLE_DISABLED_TRACK, ...this._subtitleTracks],
    });

    return this._subtitleTracks;
  }

  presentSubtitleSelection(trackIndex, { sessionId } = {}) {
    if (!this._canPresent(sessionId)) return false;

    const index = finiteTrackIndex(trackIndex);
    if (!validTrackIndex(index, this._subtitleTracks, { allowDisabled: true })) return false;

    this._selectedSubtitleTrack = index;
    this._revision += 1;
    this._notifyState();

    safeNotify(this._saveSubtitlePreference, index, this._getContentId());
    safeNotify(this._emit, "subtitle_track_changed", {
      label: subtitleSelectionLabel(this._subtitleTracks[index], index),
      track: index,
    });

    return index;
  }

  presentSubtitleOffset(offsetMs, { sessionId } = {}) {
    if (!this._canPresent(sessionId)) return false;

    const offset = normalizeSubtitleOffset(offsetMs);
    if (offset == null) return false;

    this._subtitleOffsetMs = offset;
    this._revision += 1;
    this._notifyState();
    safeNotify(this._renderSubtitleOffset, subtitleOffsetLabel(offset), offset);
    return offset;
  }

  async presentNativeSubtitleSnapshot(
    snapshot,
    { emitAvailable = true, selectTrack, selectedTrack = -1, sessionId } = {},
  ) {
    if (!this._canPresent(sessionId)) return false;

    const tracksRevision = ++this._subtitleTracksRevision;
    this._revision += 1;
    const tracks = nativeTracks(snapshot);
    if (tracks.length === 0) {
      return this.clearSubtitlePresentation({ selectTrack, sessionId });
    }

    this._subtitleTracks = tracks;
    this._notifyState();

    const target = finiteTrackIndex(selectedTrack) === -1 ? -1 : 0;
    const selectionResult = await this._applySelection(
      selectTrack,
      target,
      "native_subtitle_selection",
    );
    if (!this._subtitleTracksAreCurrent(tracksRevision, sessionId)) return false;
    if (selectionResult === false || selectionResult == null) return false;

    safeNotify(
      this._renderSubtitleOptions,
      this._subtitleTracks,
      this._selectedSubtitleTrack,
      selectTrack,
    );

    if (emitAvailable) {
      safeNotify(this._emit, "subtitle_tracks_available", {
        current: this._selectedSubtitleTrack,
        tracks: [SUBTITLE_DISABLED_TRACK, ...this._subtitleTracks],
      });
    }

    return snapshot;
  }

  clearSubtitlePresentation({ selectTrack, sessionId } = {}) {
    if (!this._canPresent(sessionId)) return false;

    this._subtitleTracksRevision += 1;
    this._subtitleTracks = Object.freeze([]);
    this._selectedSubtitleTrack = -1;
    this._revision += 1;
    this._notifyState();
    safeNotify(this._renderSubtitleOptions, this._subtitleTracks, -1, selectTrack);
    return true;
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this._revision += 1;
    return true;
  }

  _resolveAudioTarget({ activeTrack, preferredTrack }) {
    if (validTrackIndex(preferredTrack, this._audioTracks)) {
      return finiteTrackIndex(preferredTrack, 0);
    }

    const portugueseTrack = findPortugueseTrack(this._audioTracks);
    if (validTrackIndex(portugueseTrack, this._audioTracks)) return portugueseTrack;
    if (validTrackIndex(activeTrack, this._audioTracks)) return finiteTrackIndex(activeTrack, 0);
    return 0;
  }

  _resolveSubtitleTarget({ activeTrack, preferredTrack, subtitlesEnabled }) {
    if (!subtitlesEnabled || finiteTrackIndex(preferredTrack) === -1) return -1;
    if (validTrackIndex(preferredTrack, this._subtitleTracks)) {
      return finiteTrackIndex(preferredTrack);
    }
    if (validTrackIndex(activeTrack, this._subtitleTracks, { allowDisabled: true })) {
      return finiteTrackIndex(activeTrack);
    }
    return -1;
  }

  async _applySelection(selectTrack, trackIndex, operation) {
    if (typeof selectTrack !== "function") return trackIndex;

    try {
      return await selectTrack(trackIndex);
    } catch (error) {
      this._report(operation, error);
      return false;
    }
  }

  _canPresent(sessionId) {
    if (this._destroyed) return false;
    if (sessionId == null) return true;

    try {
      return this._isSessionCurrent(sessionId) !== false;
    } catch (error) {
      this._report("session_guard", error);
      return false;
    }
  }

  _audioTracksAreCurrent(revision, sessionId) {
    return (
      !this._destroyed && this._audioTracksRevision === revision && this._canPresent(sessionId)
    );
  }

  _subtitleTracksAreCurrent(revision, sessionId) {
    return (
      !this._destroyed && this._subtitleTracksRevision === revision && this._canPresent(sessionId)
    );
  }

  _notifyState() {
    safeNotify(this._onStateChange, this.snapshot());
  }

  _report(operation, error) {
    safeNotify(this._onError, operation, error);
  }
}

export function createPlayerTrackPresentationController(options) {
  return new PlayerTrackPresentationController(options);
}
