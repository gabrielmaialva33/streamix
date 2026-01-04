/**
 * Stream Loader
 *
 * Handles loading different stream types (HLS, MPEG-TS, native).
 * Extracted from video_player.js for better modularity.
 */

import Hls from "hls.js";
import mpegts from "mpegts.js";
import { getStreamingConfig } from "./streaming_config";

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
    console.log("[StreamLoader] Loading HLS:", url);

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
      console.log("[StreamLoader] HLS manifest parsed, levels:", data.levels.length);
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
      console.error("[StreamLoader] HLS error:", data);
      this.onError('hls', data);
    });

    return this.hls;
  }

  /**
   * Load MPEG-TS stream
   */
  loadMpegts(url, type = 'mpegts') {
    console.log("[StreamLoader] Loading MPEG-TS:", url, "type:", type);

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
      console.log("[StreamLoader] MPEG-TS media info:", info);
      this.onMediaInfo(info);
    });

    this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      console.error("[StreamLoader] MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError('mpegts', { errorType, errorDetail, errorInfo });
    });

    return this.mpegtsPlayer;
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
