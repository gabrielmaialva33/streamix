/**
 * Stream Loader
 *
 * Handles loading different stream types (HLS, MPEG-TS, native).
 * Extracted from video_player.js for better modularity.
 * Supports soft reload (reusing player instances) for faster channel switching.
 *
 * Player libraries (hls.js, mpegts.js) are lazy-loaded on first use
 * to keep the main bundle small for non-player pages.
 */

import { streamLogger as log } from "./logger";
import { getHls, getMpegts } from "./player_libs";
import { getStreamingConfig, StreamingMode } from "./streaming_config";

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
  const directExtensions = ["ts", "mkv", "mp4", "webm", "avi", "mov", "flv"];

  if (directExtensions.includes(currentStreamType)) {
    return currentStreamType;
  }

  if (streamUrl) {
    const url = streamUrl.toLowerCase();
    for (const ext of directExtensions) {
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
  const video = document.createElement("video");

  // Check various HEVC mime types
  const hevcTypes = [
    'video/mp4; codecs="hvc1"',
    'video/mp4; codecs="hev1"',
    'video/mp4; codecs="hevc"',
    'application/vnd.apple.mpegurl; codecs="hvc1"',
  ];

  for (const type of hevcTypes) {
    const result = video.canPlayType(type);
    if (result === "probably" || result === "maybe") {
      return true;
    }
  }

  return false;
}

/**
 * Check if HLS is supported (lightweight, no library import needed)
 */
export function isHlsSupported() {
  const mediaSource = window.MediaSource || window.ManagedMediaSource;
  if (!mediaSource) return false;
  return typeof mediaSource.isTypeSupported === "function";
}

/**
 * Check if native HLS is supported (Safari)
 */
export function isNativeHlsSupported() {
  const video = document.createElement("video");
  return video.canPlayType("application/vnd.apple.mpegurl") !== "";
}

/**
 * Lazy-load AdaptiveBufferManager only when ADAPTIVE mode is used
 */
let _AdaptiveBufferManager = null;

async function getAdaptiveBufferManager() {
  if (!_AdaptiveBufferManager) {
    const mod = await import("./adaptive_buffer");
    _AdaptiveBufferManager = mod.AdaptiveBufferManager;
  }
  return _AdaptiveBufferManager;
}

/**
 * StreamLoader class - manages HLS and MPEG-TS players
 */
export class StreamLoader {
  constructor(options = {}) {
    this.video = options.video;
    this.streamingMode = options.streamingMode || "balanced";
    this.contentType = options.contentType || "live";
    this.sessionId = options.sessionId || 0;

    // Player instances
    this.hls = null;
    this.mpegtsPlayer = null;

    // Cached library references (set after first lazy load)
    this._Hls = null;
    this._mpegts = null;

    // Adaptive buffer manager (for ADAPTIVE mode)
    this.adaptiveBufferManager = null;

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

  updateSessionId(sessionId) {
    this.sessionId = sessionId;
  }

  /**
   * Load HLS stream (async - lazy loads hls.js on first call)
   */
  async loadHls(url) {
    log.debug("Loading HLS:", url);

    const Hls = await getHls();
    this._Hls = Hls;

    if (!Hls.isSupported()) {
      throw new Error("HLS not supported");
    }

    const config = getStreamingConfig(this.streamingMode);

    // Remove internal _adaptive config before passing to HLS.js
    const hlsConfig = { ...config.hls };
    const adaptiveConfig = hlsConfig._adaptive;
    delete hlsConfig._adaptive;
    const lowLatencyTarget =
      this.streamingMode === StreamingMode.LOW_LATENCY
        ? (hlsConfig.liveSyncDuration ?? null)
        : null;

    this.hls = new Hls({
      ...hlsConfig,
      xhrSetup: (xhr) => {
        xhr.withCredentials = false;
      },
    });

    this.hls.loadSource(url);
    this.hls.attachMedia(this.video);

    // Initialize Adaptive Buffer Manager for ADAPTIVE mode
    if (this.streamingMode === StreamingMode.ADAPTIVE && adaptiveConfig) {
      try {
        const AdaptiveBufferManager = await getAdaptiveBufferManager();
        this.adaptiveBufferManager = new AdaptiveBufferManager(this.hls, adaptiveConfig);
        this.adaptiveBufferManager.start();
        log.info("[StreamLoader] Adaptive buffer management enabled");
      } catch (e) {
        log.warn("[StreamLoader] Failed to load adaptive buffer manager:", e.message);
      }
    }

    // Track bandwidth
    this.hls.on(Hls.Events.FRAG_LOADED, (_event, data) => {
      if (data.frag.stats.loaded && data.frag.stats.loading.end) {
        const loadTime = data.frag.stats.loading.end - data.frag.stats.loading.start;
        const bandwidth = (data.frag.stats.loaded * 8000) / loadTime;
        this.onFragLoaded(bandwidth, this.sessionId);
      }
    });

    this.hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
      if (lowLatencyTarget != null && "targetLatency" in this.hls) {
        this.hls.targetLatency = lowLatencyTarget;
        log.debug(`[StreamLoader] HLS target latency set to ${lowLatencyTarget}s`);
      }
      log.debug("HLS manifest parsed, levels:", data.levels.length);
      this.onManifestParsed(data, this.sessionId);
    });

    this.hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
      const level = this.hls.levels[data.level];
      this.onLevelSwitched(data.level, level, this.sessionId);
    });

    this.hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => {
      this.onAudioTracksUpdated(this.hls.audioTracks, this.sessionId);
    });

    this.hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, () => {
      this.onSubtitleTracksUpdated(this.hls.subtitleTracks, this.sessionId);
    });

    this.hls.on(Hls.Events.ERROR, (_event, data) => {
      log.error("HLS error:", data);
      this.onError("hls", data, this.sessionId);
    });

    return this.hls;
  }

  /**
   * Load MPEG-TS stream (async - lazy loads mpegts.js on first call)
   */
  async loadMpegts(url, type = "mpegts") {
    log.debug("Loading MPEG-TS:", url, "type:", type);

    const mpegts = await getMpegts();
    this._mpegts = mpegts;

    const config = getStreamingConfig(this.streamingMode);

    this.mpegtsPlayer = mpegts.createPlayer(
      {
        type: type,
        isLive: this.contentType === "live",
        url: url,
      },
      config.mpegts,
    );

    this.mpegtsPlayer.attachMediaElement(this.video);
    this.mpegtsPlayer.load();

    this.mpegtsPlayer.on(mpegts.Events.STATISTICS_INFO, (info) => {
      if (info.speed) {
        this.onStatisticsInfo(info.speed * 1000, this.sessionId);
      }
    });

    this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
      log.debug("MPEG-TS media info:", info);
      this.onMediaInfo(info, this.sessionId);
    });

    this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      log.error("MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError("mpegts", { errorType, errorDetail, errorInfo }, this.sessionId);
    });

    return this.mpegtsPlayer;
  }

  /**
   * Soft reload HLS stream (reuses existing player instance)
   * Returns true if soft reload was used, false if full reload needed
   */
  async loadHlsSoft(url) {
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
  async loadMpegtsSoft(url, type = "mpegts") {
    if (!this.mpegtsPlayer) {
      log.debug("No existing MPEG-TS instance, using full load");
      return this.loadMpegts(url, type);
    }

    log.debug("Soft reloading MPEG-TS:", url);

    const mpegts = this._mpegts || (await getMpegts());
    this._mpegts = mpegts;

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
      config.mpegts,
    );

    if (wasAttached) {
      this.mpegtsPlayer.attachMediaElement(this.video);
    }
    this.mpegtsPlayer.load();

    // Re-attach event listeners
    this.mpegtsPlayer.on(mpegts.Events.STATISTICS_INFO, (info) => {
      if (info.speed) {
        this.onStatisticsInfo(info.speed * 1000, this.sessionId);
      }
    });

    this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
      log.debug("MPEG-TS media info:", info);
      this.onMediaInfo(info, this.sessionId);
    });

    this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      log.error("MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError("mpegts", { errorType, errorDetail, errorInfo }, this.sessionId);
    });

    return this.mpegtsPlayer;
  }

  /**
   * Check if soft reload is available for current stream type
   */
  canSoftReload(streamType) {
    if (streamType === "hls" && this.hls) return true;
    if (streamType === "ts" && this.mpegtsPlayer) return true;
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
    if (!this.hls?.levels) return [];

    return this.hls.levels.map((level, index) => ({
      index,
      height: level.height,
      width: level.width,
      bitrate: level.bitrate,
      frameRate: level.frameRate || level.attrs?.["FRAME-RATE"] || null,
      videoCodec: level.videoCodec || null,
      audioCodec: level.audioCodec || null,
      codecs: level.attrs?.CODECS || level.codecs || null,
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
    // Stop adaptive buffer manager first
    if (this.adaptiveBufferManager) {
      this.adaptiveBufferManager.stop();
      this.adaptiveBufferManager = null;
    }

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

  /**
   * Get adaptive buffer status (for debugging/UI)
   */
  getAdaptiveBufferStatus() {
    if (this.adaptiveBufferManager) {
      return this.adaptiveBufferManager.getStatus();
    }
    return null;
  }
}

export default StreamLoader;
