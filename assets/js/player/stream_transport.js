import { playerLogger as log } from "../core/logger.js";
import { StreamLoader } from "../media/stream_loader.js";
import { assertActivationHost } from "./playback_engine_activation.js";

export const STREAM_TRANSPORT_HOST_METHODS = Object.freeze([
  "adoptHlsEngine",
  "getCodecAbr",
  "getContentType",
  "getCurrentUrl",
  "getNetworkMonitor",
  "getPresentation",
  "getSessionId",
  "getStreamingMode",
  "getVideo",
  "handleStreamError",
  "isManualQuality",
  "isSessionCurrent",
  "playNativeAfterResume",
  "pushEvent",
  "showQualityChange",
  "updateAudioTracks",
  "updateQualityList",
  "updateSubtitleTracks",
]);

const defaultDependencies = {
  createStreamLoader: (options) => new StreamLoader(options),
};

/**
 * Owns the StreamLoader instance for the current playback session.
 *
 * The loader remains the HLS/MPEG-TS transport owner. This module owns its
 * lifecycle (idempotent creation, teardown and the teardown promise the
 * engine activations wait on), wires every loader callback behind a session
 * guard, and exposes the small transport surface the hook still needs
 * (quality, streaming mode, track fallbacks, HLS recovery context).
 */
export class StreamTransport {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(host, STREAM_TRANSPORT_HOST_METHODS, "StreamTransport");
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;
    this.loader = null;
    this.teardownPromise = Promise.resolve();
  }

  get current() {
    return this.loader;
  }

  ensure() {
    if (this.loader) {
      this.loader.updateSessionId(this.host.getSessionId());
      return this.loader;
    }

    this.loader = this.deps.createStreamLoader({
      video: this.host.getVideo(),
      streamingMode: this.host.getStreamingMode(),
      contentType: this.host.getContentType(),
      sessionId: this.host.getSessionId(),
      ...this.callbacks(),
    });

    return this.loader;
  }

  release(loader) {
    if (loader && this.loader === loader) {
      this.loader = null;
      return true;
    }
    return false;
  }

  teardown() {
    const loader = this.loader;
    if (!loader) return this.teardownPromise;

    this.loader = null;
    try {
      this.teardownPromise = Promise.resolve(loader.destroy()).catch((error) =>
        this.logger.debug("[VideoPlayer] StreamLoader teardown failed:", error),
      );
    } catch (error) {
      this.logger.debug("[VideoPlayer] StreamLoader teardown failed:", error);
      this.teardownPromise = Promise.resolve();
    }

    return this.teardownPromise;
  }

  awaitTeardown() {
    return this.teardownPromise || Promise.resolve();
  }

  recoveryContext({ sessionId, url }) {
    const loader = this.loader;

    return {
      isCurrent: () =>
        !!loader &&
        this.host.isSessionCurrent(sessionId) &&
        this.loader === loader &&
        this.host.getCurrentUrl() === url,
      loader,
      url,
    };
  }

  updateStreamingMode(mode) {
    if (!this.loader) return false;
    this.loader.updateStreamingMode(mode);
    return true;
  }

  setQuality(levelIndex) {
    if (!this.loader) return false;
    this.loader.setQuality(levelIndex);
    return true;
  }

  qualityLevels() {
    return this.loader?.getQualityLevels() ?? [];
  }

  currentLevel() {
    return this.loader?.getCurrentLevel() ?? -1;
  }

  setAudioTrack(trackIndex) {
    return this.loader?.setAudioTrack(trackIndex);
  }

  setSubtitleTrack(trackIndex) {
    return this.loader?.setSubtitleTrack(trackIndex);
  }

  destroy() {
    return this.teardown();
  }

  callbacks() {
    const host = this.host;
    const current = (sessionId) => host.isSessionCurrent(sessionId);

    return {
      onManifestParsed: (data, sessionId) => {
        if (!current(sessionId)) return;
        if (!host.adoptHlsEngine(sessionId)) return;

        this.logger.info("Manifest parsed, levels:", data?.levels?.length);
        const presentation = host.getPresentation();
        presentation?.hideLoading();
        presentation?.hideError();
        host.updateQualityList();
        host.updateAudioTracks();
        host.updateSubtitleTracks();

        host.playNativeAfterResume(sessionId);
      },
      onError: (type, data, sessionId) => {
        if (current(sessionId)) host.handleStreamError(type, data);
      },
      onLevelSwitched: (level, levelData, sessionId) => {
        if (!current(sessionId)) return;

        // Keep codec-aware ABR pointed at the codec actually being decoded,
        // otherwise its suggestions stay anchored to the first level's codec.
        const codecAbr = host.getCodecAbr();
        if (codecAbr && levelData?.codec) codecAbr.setCodec(levelData.codec);

        const isAuto = !host.isManualQuality();
        host.pushEvent("quality_switched", {
          level,
          height: levelData?.height,
          bitrate: levelData?.bitrate,
          auto: isAuto,
        });

        if (isAuto && levelData?.height) {
          host.showQualityChange(`Auto: ${levelData.height}p`);
        }
      },
      onAudioTracksUpdated: (_tracks, sessionId) => {
        if (!current(sessionId)) return;
        if (!host.adoptHlsEngine(sessionId)) return;
        host.updateAudioTracks();
      },
      onSubtitleTracksUpdated: (_tracks, sessionId) => {
        if (!current(sessionId)) return;
        if (!host.adoptHlsEngine(sessionId)) return;
        host.updateSubtitleTracks();
      },
      onFragLoaded: (bandwidth, sessionId) => {
        if (!current(sessionId)) return;

        host.getNetworkMonitor()?.addSample(bandwidth);
        // Codec-aware ABR works in kbps.
        host.getCodecAbr()?.recordBandwidth(bandwidth / 1000);
      },
      onMediaInfo: (_info, sessionId) => {
        if (!current(sessionId)) return;

        const presentation = host.getPresentation();
        presentation?.hideLoading();
        presentation?.hideError();
      },
      onStatisticsInfo: (bps, sessionId) => {
        if (current(sessionId)) host.getNetworkMonitor()?.addSample(bps);
      },
    };
  }
}

export function createStreamTransport(options) {
  return new StreamTransport(options);
}
