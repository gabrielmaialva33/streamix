/**
 * Stream Loader
 *
 * Handles loading different stream types (HLS, MPEG-TS, native).
 * Extracted from video_player.js for better modularity.
 * Supports soft reload (reusing player instances) for faster channel switching.
 */

import Hls from "hls.js";
import mpegts from "mpegts.js";
import { getStreamingConfig } from "./streaming_config";
import { streamLogger as log } from "./logger";

/**
 * Stream type detection from URL
 */
export function getStreamType(url) {
  if (!url) return "unknown";
  const lowercaseUrl = url.toLowerCase();

  if (lowercaseUrl.includes(".m3u8") || lowercaseUrl.includes("/hls/")) {
    return "hls";
  }
  if (lowercaseUrl.endsWith(".ts") || lowercaseUrl.includes(".ts?")) {
    return "ts";
  }
  if (lowercaseUrl.includes(".mp4")) {
    return "mp4";
  }
  if (lowercaseUrl.includes(".mkv")) {
    return "mkv";
  }
  if (lowercaseUrl.includes(".flv")) {
    return "flv";
  }
  if (lowercaseUrl.includes("/live/") && lowercaseUrl.includes("/")) {
    return "xtream";
  }
  return "unknown";
}

/**
 * Get file extension for format detection
 */
export function getFileExtension(streamUrl, sourceType, currentStreamType) {
  const videoExtensions = ["mkv", "mp4", "webm", "avi", "mov", "flv"];

  if (videoExtensions.includes(currentStreamType)) {
    return currentStreamType;
  }

  if (streamUrl) {
    const url = streamUrl.toLowerCase();
    for (const ext of videoExtensions) {
      if (url.includes(`.${ext}`)) {
        return ext;
      }
    }
  }

  // Default to mkv for GIndex sources
  if (sourceType === "gindex") {
    return "mkv";
  }

  return null;
}

/**
 * Check if browser supports HEVC natively
 */
export function supportsHEVCNatively() {
  const video = document.createElement('video');

  // Check various HEVC mime types
  const hevcTypes = [
    'video/mp4; codecs="hvc1"',
    'video/mp4; codecs="hev1"',
    'video/mp4; codecs="hevc"',
    'application/vnd.apple.mpegurl; codecs="hvc1"',
  ];

  for (const type of hevcTypes) {
    const result = video.canPlayType(type);
    if (result === 'probably' || result === 'maybe') {
      return true;
    }
  }

  return false;
}

/**
 * Check if HLS is supported
 */
export function isHlsSupported() {
  return Hls.isSupported();
}

/**
 * Check if MPEG-TS is supported
 */
export function isMpegtsSupported() {
  return mpegts.getFeatureList().mseLivePlayback;
}

/**
 * Check if native HLS is supported (Safari)
 */
export function isNativeHlsSupported() {
  const video = document.createElement('video');
  return video.canPlayType('application/vnd.apple.mpegurl') !== '';
}

/**
 * StreamLoader class - manages HLS and MPEG-TS players
 */
export class StreamLoader {
  constructor(options = {}) {
    this.video = options.video;
    this.streamingMode = options.streamingMode || 'balanced';
    this.contentType = options.contentType || 'live';

    // Player instances
    this.hls = null;
    this.mpegtsPlayer = null;

    // Callbacks
    this.onManifestParsed = options.onManifestParsed || (() => {});
    this.onError = options.onError || (() => {});
    this.onLevelSwitched = options.onLevelSwitched || (() => {});
    this.onAudioTracksUpdated = options.onAudioTracksUpdated || (() => {});
    this.onSubtitleTracksUpdated = options.onSubtitleTracksUpdated || (() => {});
    this.onFragLoaded = options.onFragLoaded || (() => {});
    this.onMediaInfo = options.onMediaInfo || (() => {});
    this.onStatisticsInfo = options.onStatisticsInfo || (() => {});
  }

  /**
   * Load HLS stream
   */
  loadHls(url) {
    log.debug("Loading HLS:", url);

    if (!Hls.isSupported()) {
      throw new Error('HLS not supported');
    }

    const config = getStreamingConfig(this.streamingMode);

    this.hls = new Hls({
      ...config.hls,
      xhrSetup: (xhr) => {
        xhr.withCredentials = false;
      },
    });

    this.hls.loadSource(url);
    this.hls.attachMedia(this.video);

    // Track bandwidth
    this.hls.on(Hls.Events.FRAG_LOADED, (_event, data) => {
      if (data.frag.stats.loaded && data.frag.stats.loading.end) {
        const loadTime = data.frag.stats.loading.end - data.frag.stats.loading.start;
        const bandwidth = (data.frag.stats.loaded * 8000) / loadTime;
        this.onFragLoaded(bandwidth);
      }
    });

    this.hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
      log.debug("HLS manifest parsed, levels:", data.levels.length);
      this.onManifestParsed(data);
    });

    this.hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
      const level = this.hls.levels[data.level];
      this.onLevelSwitched(data.level, level);
    });

    this.hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => {
      this.onAudioTracksUpdated(this.hls.audioTracks);
    });

    this.hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, () => {
      this.onSubtitleTracksUpdated(this.hls.subtitleTracks);
    });

    this.hls.on(Hls.Events.ERROR, (_event, data) => {
      log.error("HLS error:", data);
      this.onError('hls', data);
    });

    return this.hls;
  }

  /**
   * Load MPEG-TS stream
   */
  loadMpegts(url, type = 'mpegts') {
    log.debug("Loading MPEG-TS:", url, "type:", type);

    const config = getStreamingConfig(this.streamingMode);

    this.mpegtsPlayer = mpegts.createPlayer(
      {
        type: type,
        isLive: this.contentType === "live",
        url: url,
      },
      config.mpegts
    );

    this.mpegtsPlayer.attachMediaElement(this.video);
    this.mpegtsPlayer.load();

    this.mpegtsPlayer.on(mpegts.Events.STATISTICS_INFO, (info) => {
      if (info.speed) {
        this.onStatisticsInfo(info.speed * 1000);
      }
    });

    this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
      log.debug("MPEG-TS media info:", info);
      this.onMediaInfo(info);
    });

    this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      log.error("MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError('mpegts', { errorType, errorDetail, errorInfo });
    });

    return this.mpegtsPlayer;
  }

  /**
   * Soft reload HLS stream (reuses existing player instance)
   * Returns true if soft reload was used, false if full reload needed
   */
  loadHlsSoft(url) {
    if (!this.hls) {
      log.debug("No existing HLS instance, using full load");
      return this.loadHls(url);
    }

    log.debug("Soft reloading HLS:", url);

    // Stop current loading
    this.hls.stopLoad();

    // Load new source
    this.hls.loadSource(url);
    this.hls.startLoad();

    return this.hls;
  }

  /**
   * Soft reload MPEG-TS stream (reuses existing player instance)
   * Returns player instance
   */
  loadMpegtsSoft(url, type = 'mpegts') {
    if (!this.mpegtsPlayer) {
      log.debug("No existing MPEG-TS instance, using full load");
      return this.loadMpegts(url, type);
    }

    log.debug("Soft reloading MPEG-TS:", url);

    // Unload current stream but keep player
    this.mpegtsPlayer.unload();

    // mpegts.js doesn't support changing URL, need to destroy and recreate
    // But we can skip the attachMediaElement step
    const config = getStreamingConfig(this.streamingMode);
    const wasAttached = this.mpegtsPlayer._mediaElement;

    this.mpegtsPlayer.destroy();

    this.mpegtsPlayer = mpegts.createPlayer(
      {
        type: type,
        isLive: this.contentType === "live",
        url: url,
      },
      config.mpegts
    );

    if (wasAttached) {
      this.mpegtsPlayer.attachMediaElement(this.video);
    }
    this.mpegtsPlayer.load();

    // Re-attach event listeners
    this.mpegtsPlayer.on(mpegts.Events.STATISTICS_INFO, (info) => {
      if (info.speed) {
        this.onStatisticsInfo(info.speed * 1000);
      }
    });

    this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
      log.debug("MPEG-TS media info:", info);
      this.onMediaInfo(info);
    });

    this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      log.error("MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError('mpegts', { errorType, errorDetail, errorInfo });
    });

    return this.mpegtsPlayer;
  }

  /**
   * Check if soft reload is available for current stream type
   */
  canSoftReload(streamType) {
    if (streamType === 'hls' && this.hls) return true;
    if (streamType === 'ts' && this.mpegtsPlayer) return true;
    return false;
  }

  /**
   * Get HLS instance
   */
  getHls() {
    return this.hls;
  }

  /**
   * Get MPEG-TS player instance
   */
  getMpegtsPlayer() {
    return this.mpegtsPlayer;
  }

  /**
   * Update streaming mode configuration
   */
  updateStreamingMode(newMode) {
    this.streamingMode = newMode;

    if (this.hls) {
      const config = getStreamingConfig(newMode);
      Object.keys(config.hls).forEach((key) => {
        if (key in this.hls.config) {
          this.hls.config[key] = config.hls[key];
        }
      });
    }
  }

  /**
   * Set quality level (HLS only)
   */
  setQuality(levelIndex) {
    if (this.hls) {
      this.hls.currentLevel = levelIndex;
    }
  }

  /**
   * Set audio track (HLS only)
   */
  setAudioTrack(trackIndex) {
    if (this.hls) {
      this.hls.audioTrack = trackIndex;
    }
  }

  /**
   * Set subtitle track (HLS only)
   */
  setSubtitleTrack(trackIndex) {
    if (this.hls) {
      this.hls.subtitleTrack = trackIndex;
    }
  }

  /**
   * Get available quality levels (HLS only)
   */
  getQualityLevels() {
    if (!this.hls || !this.hls.levels) return [];

    return this.hls.levels.map((level, index) => ({
      index,
      height: level.height,
      width: level.width,
      bitrate: level.bitrate,
      label: level.height ? `${level.height}p` : `${Math.round(level.bitrate / 1000)}k`,
    }));
  }

  /**
   * Get current quality level (HLS only)
   */
  getCurrentLevel() {
    return this.hls?.currentLevel ?? -1;
  }

  /**
   * Try to recover from HLS media error
   */
  recoverMediaError() {
    if (this.hls) {
      this.hls.recoverMediaError();
    }
  }

  /**
   * Restart HLS loading
   */
  startLoad() {
    if (this.hls) {
      this.hls.startLoad();
    }
  }

  /**
   * Destroy all players
   */
  destroy() {
    if (this.hls) {
      this.hls.destroy();
      this.hls = null;
    }

    if (this.mpegtsPlayer) {
      this.mpegtsPlayer.pause();
      this.mpegtsPlayer.unload();
      this.mpegtsPlayer.detachMediaElement();
      this.mpegtsPlayer.destroy();
      this.mpegtsPlayer = null;
    }
  }
}

export default StreamLoader;
