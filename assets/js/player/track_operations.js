import { playerLogger as log } from "../core/logger.js";
import { assertActivationHost } from "./playback_engine_activation.js";
import { hasSubtitleInLanguage } from "./track_metadata.js";

export const EXTERNAL_SUBTITLE_LABEL = "Português (auto)";

export const TRACK_OPERATIONS_HOST_METHODS = Object.freeze([
  "getNativeSubtitleController",
  "getOrchestrator",
  "getPresentation",
  "getSessionId",
  "getStreamTransport",
  "getSubtitleSourceResolver",
  "getTrackState",
  "hasActiveAVPlayer",
  "isSessionCurrent",
  "setAudioTrack",
  "setSubtitleTrack",
  "updateSubtitleTracks",
]);

/**
 * Engine-facing track operations for the player hook.
 *
 * Applies audio/subtitle selections, subtitle offsets, and external subtitle
 * loads against the active engine (through the PlaybackOrchestrator, or the
 * StreamTransport when no orchestrator is attached), then hands the outcome to
 * the presentation controller. Every operation captures the playback session
 * up front and drops results that arrive after the session was superseded.
 * The instance also owns the external subtitle source lease used by AVPlayer
 * loads, so the lease is released when it is replaced or the player is torn
 * down.
 */
export class TrackOperations {
  constructor({ host, logger = log } = {}) {
    this.host = assertActivationHost(host, TRACK_OPERATIONS_HOST_METHODS, "TrackOperations");
    this.logger = logger;
    this.externalSubtitleLease = null;
    this.destroyed = false;
  }

  async selectAudioTrack(trackIndex) {
    const sessionId = this.host.getSessionId();
    const orchestrator = this.host.getOrchestrator();
    const result = orchestrator
      ? await orchestrator.selectAudioTrack(trackIndex)
      : this.host.getStreamTransport()?.setAudioTrack(trackIndex);

    if (result === false || result == null || !this.host.isSessionCurrent(sessionId)) {
      return false;
    }

    const presented = this.host.getPresentation()?.presentAudioSelection(trackIndex, {
      sessionId,
    });
    return presented === false ? false : result;
  }

  async refreshAudioTracks() {
    const sessionId = this.host.getSessionId();
    const refreshedTracks = await this.host.getOrchestrator()?.refreshAudioTracks();
    if (!this.host.isSessionCurrent(sessionId)) return false;

    const snapshot = this.host.getOrchestrator()?.trackSnapshot?.();
    const tracks = Array.isArray(refreshedTracks) ? refreshedTracks : (snapshot?.audioTracks ?? []);

    return (
      this.host.getPresentation()?.presentAudioTracks({
        activeTrack: snapshot?.selectedAudioTrack ?? 0,
        preferredTrack: this.host.getTrackState().preferredAudioTrack,
        selectTrack: (index) => this.host.setAudioTrack(index),
        sessionId,
        tracks,
      }) ?? []
    );
  }

  async selectSubtitleTrack(trackIndex) {
    const sessionId = this.host.getSessionId();
    const orchestrator = this.host.getOrchestrator();
    let result = orchestrator
      ? await orchestrator.selectSubtitleTrack(trackIndex)
      : this.host.getStreamTransport()?.setSubtitleTrack(trackIndex);

    const nativeResult = this.host.getNativeSubtitleController()?.select(trackIndex);
    if (nativeResult !== false && nativeResult != null) result = nativeResult;

    if (result === false || result == null || !this.host.isSessionCurrent(sessionId)) {
      return false;
    }

    const presented = this.host.getPresentation()?.presentSubtitleSelection(trackIndex, {
      sessionId,
    });
    if (presented === false) return false;

    await this.host.getOrchestrator()?.setSubtitleDelay(this.host.getTrackState().subtitleOffsetMs);
    return this.host.isSessionCurrent(sessionId) ? result : false;
  }

  async setSubtitleOffset(offsetMs) {
    const sessionId = this.host.getSessionId();
    const normalizedOffset = this.host.getPresentation()?.presentSubtitleOffset(offsetMs, {
      sessionId,
    });
    if (normalizedOffset === false || normalizedOffset == null) return false;

    const engineResult = await this.host.getOrchestrator()?.setSubtitleDelay(normalizedOffset);
    if (!this.host.isSessionCurrent(sessionId)) return false;
    if (engineResult !== false && engineResult != null) return engineResult;

    const { selectedSubtitleTrack: selectedTrack, subtitleLang } = this.host.getTrackState();
    const scheduled = this.host.getNativeSubtitleController()?.scheduleReload(
      {
        sessionId,
        offsetMs: normalizedOffset,
        language: subtitleLang,
        label: EXTERNAL_SUBTITLE_LABEL,
      },
      (snapshot) => this.applyNativeSubtitleReloadResult(snapshot, { selectedTrack, sessionId }),
    );

    return scheduled ? normalizedOffset : false;
  }

  async reloadNativeExternalSubtitle(
    selectedTrack = this.host.getTrackState().selectedSubtitleTrack,
  ) {
    const sessionId = this.host.getSessionId();
    const { subtitleLang, subtitleOffsetMs } = this.host.getTrackState();
    const snapshot = await this.host.getNativeSubtitleController()?.reload({
      sessionId,
      offsetMs: subtitleOffsetMs,
      language: subtitleLang,
      label: EXTERNAL_SUBTITLE_LABEL,
    });

    return this.applyNativeSubtitleReloadResult(snapshot, { selectedTrack, sessionId });
  }

  async applyNativeSubtitleReloadResult(snapshot, { selectedTrack, sessionId }) {
    if (!this.host.isSessionCurrent(sessionId)) return false;

    return this.applyNativeSubtitleSnapshot(snapshot, selectedTrack, { sessionId });
  }

  async applyNativeSubtitleSnapshot(
    snapshot,
    selectedTrack,
    { emitAvailable = true, sessionId = this.host.getSessionId() } = {},
  ) {
    return (
      this.host.getPresentation()?.presentNativeSubtitleSnapshot(snapshot, {
        emitAvailable,
        selectTrack: (index) => this.host.setSubtitleTrack(index),
        selectedTrack,
        sessionId,
      }) ?? false
    );
  }

  clearNativeSubtitlePresentation(sessionId = this.host.getSessionId()) {
    return (
      this.host.getPresentation()?.clearSubtitlePresentation({
        selectTrack: (index) => this.host.setSubtitleTrack(index),
        sessionId,
      }) ?? false
    );
  }

  async refreshSubtitleTracks() {
    const sessionId = this.host.getSessionId();
    const refreshedTracks = await this.host.getOrchestrator()?.refreshSubtitleTracks();
    if (!this.host.isSessionCurrent(sessionId)) return false;

    const snapshot = this.host.getOrchestrator()?.trackSnapshot?.();
    const tracks = Array.isArray(refreshedTracks)
      ? refreshedTracks
      : (snapshot?.subtitleTracks ?? []);
    const { preferredSubtitleTrack, subtitlesEnabled } = this.host.getTrackState();

    return (
      this.host.getPresentation()?.presentSubtitleTracks({
        activeTrack: snapshot?.selectedSubtitleTrack ?? -1,
        preferredTrack: preferredSubtitleTrack,
        selectTrack: (index) => this.host.setSubtitleTrack(index),
        sessionId,
        subtitlesEnabled,
        tracks,
      }) ?? []
    );
  }

  /**
   * Loads the external subtitle for the current AVPlayer session. The
   * resolver hands out a lease for the subtitle source; the lease is kept
   * only after the engine accepted the subtitle and released on every other
   * path.
   */
  async loadExternalSubtitle(sessionId = this.host.getSessionId()) {
    const { imdbId, subtitleLang, subtitleTracks } = this.host.getTrackState();
    if (!imdbId || !this.host.hasActiveAVPlayer()) return false;
    if (hasSubtitleInLanguage(subtitleTracks, subtitleLang)) return false;

    let sourceLease = null;

    try {
      sourceLease = await this.host.getSubtitleSourceResolver()?.resolve({
        sessionId,
        imdbId,
        language: subtitleLang,
        offsetMs: 0,
      });
      if (!sourceLease) return false;
      if (!this.host.isSessionCurrent(sessionId)) {
        this.releaseLease(sourceLease);
        return false;
      }

      const result = await this.host.getOrchestrator()?.loadExternalSubtitle({
        source: sourceLease.source,
        lang: subtitleLang,
        title: EXTERNAL_SUBTITLE_LABEL,
      });
      if (result === false || result == null) {
        this.releaseLease(sourceLease);
        return false;
      }

      this.releaseExternalSubtitleLease();
      this.externalSubtitleLease = sourceLease;
      sourceLease = null;

      if (this.host.isSessionCurrent(sessionId)) {
        await this.host.updateSubtitleTracks();
      }

      this.logger.debug("[VideoPlayer] External subtitle loaded for", imdbId);
      return result;
    } catch (error) {
      this.releaseLease(sourceLease);
      this.logger.warn("[VideoPlayer] External subtitle load failed:", error);
      return false;
    }
  }

  async loadNativeExternalSubtitle(sessionId = this.host.getSessionId(), force = false) {
    const nativeSubtitles = this.host.getNativeSubtitleController();
    const { imdbId, sourceType, subtitleLang, subtitleOffsetMs } = this.host.getTrackState();
    if (!imdbId || !nativeSubtitles || sourceType !== "torrent") return false;

    const snapshot = await nativeSubtitles.load({
      sessionId,
      force,
      language: subtitleLang,
      label: EXTERNAL_SUBTITLE_LABEL,
      offsetMs: subtitleOffsetMs,
    });
    if (!snapshot || !this.host.isSessionCurrent(sessionId)) return false;

    const { preferredSubtitleTrack, subtitlesEnabled } = this.host.getTrackState();
    const preferredTrack = subtitlesEnabled && preferredSubtitleTrack !== -1 ? 0 : -1;
    await this.applyNativeSubtitleSnapshot(snapshot, preferredTrack);
    this.logger.debug("[VideoPlayer] Native external subtitle loaded for", imdbId);
    return snapshot;
  }

  releaseLease(lease) {
    if (!lease?.release) return;

    try {
      lease.release();
    } catch (error) {
      this.logger.debug("[VideoPlayer] External subtitle source cleanup failed:", error);
    }
  }

  releaseExternalSubtitleLease() {
    const lease = this.externalSubtitleLease;
    this.externalSubtitleLease = null;
    this.releaseLease(lease);
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.releaseExternalSubtitleLease();
  }
}

export function createTrackOperations(options) {
  return new TrackOperations(options);
}
