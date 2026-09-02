import { playerLogger as log } from "../core/logger.js";
import { assertActivationHost } from "./playback_engine_activation.js";

export const TRACK_PROBE_AUTO_SWITCH_DELAY_MS = 500;
export const TRACK_PROBE_CONTENT_TYPES = Object.freeze(["movie", "episode"]);

export const TRACK_PROBE_HOST_METHODS = Object.freeze([
  "getContentId",
  "getContentType",
  "getResourcePolicy",
  "getSessionId",
  "getVideo",
  "hasAVPlayer",
  "isDestroyed",
  "isSessionCurrent",
  "isSwitchingToAVPlayer",
  "isUsingAVPlayer",
  "prefersAVPlayer",
  "presentProbedTracks",
  "setAudioTrack",
  "setSubtitleTrack",
  "switchToAVPlayerWithTrack",
  "updateAudioTracks",
  "updateSubtitleTracks",
]);

const defaultDependencies = {
  fetchJson: async (url) => {
    const response = await globalThis.fetch(url, { headers: { Accept: "application/json" } });
    return { ok: response.ok, status: response.status, json: () => response.json() };
  },
  timerApi: globalThis,
};

/**
 * Background track probe for GIndex content.
 *
 * Native playback starts immediately; this controller asks the server-side
 * ffprobe cache for the audio/subtitle tracks, presents them, and applies the
 * dual-audio policy (auto-switch to AVPlayer with the preferred track unless
 * the resource policy asks to wait for the user). It also owns what happens
 * when the user picks a probed track: apply it on an active AVPlayer, or
 * switch engines carrying the current position.
 */
export class TrackProbeController {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(host, TRACK_PROBE_HOST_METHODS, "TrackProbeController");
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;
    this.probed = false;
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.destroyed = false;
  }

  hasProbedAudioTrack(trackIndex) {
    return Boolean(this.audioTracks[trackIndex]);
  }

  async probe() {
    if (this.destroyed || this.probed || this.host.isUsingAVPlayer() || this.host.isDestroyed()) {
      return false;
    }
    this.probed = true;

    const sessionId = this.host.getSessionId();
    const policy = this.host.getResourcePolicy();
    if (!policy?.shouldProbeTracks) {
      this.logger.debug("[VideoPlayer] Skipping track probe:", policy?.reason);
      return false;
    }

    const contentId = this.host.getContentId();
    const contentType = this.host.getContentType();
    if (!contentId || !TRACK_PROBE_CONTENT_TYPES.includes(contentType)) return false;

    this.logger.debug("[VideoPlayer] Probing GIndex tracks via API...");

    try {
      const response = await this.deps.fetchJson(`/api/gindex-tracks/${contentType}/${contentId}`);
      if (this.host.isDestroyed() || !this.host.isSessionCurrent(sessionId)) return false;
      if (!response.ok) {
        this.logger.debug("[VideoPlayer] Track probe API returned", response.status, "— skipping");
        return false;
      }

      const data = await response.json();
      if (this.host.isDestroyed()) return false;

      const audio = Array.isArray(data?.audio) ? data.audio : [];
      const subtitle = Array.isArray(data?.subtitle) ? data.subtitle : [];

      const presentation = this.host.presentProbedTracks({
        audioTracks: audio,
        onAudioSelect: (trackIndex) => this.selectAudioTrack(trackIndex),
        onSubtitleSelect: (trackIndex) => this.selectSubtitleTrack(trackIndex),
        sessionId,
        subtitleTracks: subtitle,
      });

      this.audioTracks = [...(presentation?.audioTracks ?? [])];
      this.subtitleTracks = [...(presentation?.subtitleTracks ?? [])];
      const preferredAudioTrack = presentation?.selectedAudioTrack ?? 0;

      if (this.host.isDestroyed()) return false;

      // Dual audio: the native player cannot reliably pick PT-BR, so bridge
      // to AVPlayer with the preferred track unless policy wants the user to
      // decide.
      if (this.audioTracks.length > 1) {
        if (policy.avoidSpeculativeWork && !this.host.prefersAVPlayer()) {
          this.logger.debug(
            "[VideoPlayer] Dual audio detected, waiting for user selection:",
            policy.reason,
          );
          return true;
        }

        this.logger.debug(
          "[VideoPlayer] Multiple audio tracks detected, auto-switching to AVPlayer with Portuguese track",
          preferredAudioTrack,
        );
        await new Promise((resolve) =>
          this.deps.timerApi.setTimeout(resolve, TRACK_PROBE_AUTO_SWITCH_DELAY_MS),
        );
        if (!this.host.isDestroyed() && !this.destroyed) {
          await this.selectAudioTrack(preferredAudioTrack);
        }
      }

      return true;
    } catch (error) {
      this.logger.debug("[VideoPlayer] Track probe API call failed:", error?.message);
      return false;
    }
  }

  async selectAudioTrack(trackIndex) {
    if (this.host.isSwitchingToAVPlayer()) {
      this.logger.debug("[VideoPlayer] Already switching to AVPlayer, ignoring...");
      return false;
    }

    // An active AVPlayer refreshes its concrete capabilities first.
    if (this.host.isUsingAVPlayer() && this.host.hasAVPlayer()) {
      const tracks = await this.host.updateAudioTracks();
      if (tracks?.[trackIndex]) await this.host.setAudioTrack(trackIndex);
      return true;
    }

    this.logger.debug("[VideoPlayer] User selected audio track, switching to AVPlayer...");
    return this.switchWithTrack("audio", trackIndex);
  }

  async selectSubtitleTrack(trackIndex) {
    if (this.host.isSwitchingToAVPlayer()) {
      this.logger.debug("[VideoPlayer] Already switching to AVPlayer, ignoring...");
      return false;
    }

    if (this.host.isUsingAVPlayer() && this.host.hasAVPlayer()) {
      const tracks = await this.host.updateSubtitleTracks();
      if (trackIndex === -1 || tracks?.[trackIndex]) await this.host.setSubtitleTrack(trackIndex);
      return true;
    }

    if (trackIndex === -1) {
      this.logger.debug("[VideoPlayer] Subtitles disabled, staying on native");
      return false;
    }

    this.logger.debug("[VideoPlayer] User selected subtitle track, switching to AVPlayer...");
    return this.switchWithTrack("subtitle", trackIndex);
  }

  switchWithTrack(trackType, trackIndex) {
    const video = this.host.getVideo();
    const currentTime = Number(video?.currentTime) || 0;
    const wasPlaying = video ? !video.paused : false;
    return this.host.switchToAVPlayerWithTrack(trackType, trackIndex, currentTime, wasPlaying);
  }

  snapshot() {
    return Object.freeze({
      audioTracks: this.audioTracks.length,
      probed: this.probed,
      subtitleTracks: this.subtitleTracks.length,
    });
  }

  destroy() {
    this.destroyed = true;
  }
}

export function createTrackProbeController(options) {
  return new TrackProbeController(options);
}
