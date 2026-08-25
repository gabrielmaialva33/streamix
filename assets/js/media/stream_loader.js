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

import { streamLogger as log } from "../core/logger.js";
import { createHlsPlaybackEngine } from "../player/hls_playback_engine.js";
import { createMpegtsPlaybackEngine } from "../player/mpegts_playback_engine.js";
import { getHls, getMpegts } from "./player_libs.js";
import { getStreamingConfig, StreamingMode } from "./streaming_config.js";

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
    const mod = await import("./adaptive_buffer.js");
    _AdaptiveBufferManager = mod.AdaptiveBufferManager;
  }
  return _AdaptiveBufferManager;
}

export class StreamLoaderCancelledError extends Error {
  constructor() {
    super("Stream loader operation was cancelled");
    this.name = "StreamLoaderCancelledError";
  }
}

export const isStreamLoaderCancelledError = (error) =>
  error instanceof StreamLoaderCancelledError || error?.name === "StreamLoaderCancelledError";

/**
 * StreamLoader class - manages HLS and MPEG-TS players
 */
export class StreamLoader {
  constructor(options = {}) {
    this.video = options.video;
    this.streamingMode = options.streamingMode || "balanced";
    this.contentType = options.contentType || "live";
    this.sessionId = options.sessionId || 0;
    this.disposed = false;
    this._hlsLoadToken = 0;
    this._mpegtsLoadToken = 0;
    this._destroyedHlsInstances = new WeakSet();
    this._destroyedMpegtsInstances = new WeakSet();
    this._dependencies = {
      createHlsPlaybackEngine: options.createHlsPlaybackEngine || createHlsPlaybackEngine,
      getAdaptiveBufferManager: options.getAdaptiveBufferManager || getAdaptiveBufferManager,
      getHls: options.getHls || getHls,
      getMpegts: options.getMpegts || getMpegts,
    };

    // Player instances
    this.hls = null;
    this.hlsEngine = null;
    this.mpegtsPlayer = null;
    this.mpegtsEngine = null;

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
    if (this.disposed) return;
    this.sessionId = sessionId;
  }

  _isHlsLoadCurrent(token) {
    return !this.disposed && token === this._hlsLoadToken;
  }

  _isMpegtsLoadCurrent(token) {
    return !this.disposed && token === this._mpegtsLoadToken;
  }

  _assertHlsLoadCurrent(token, hls = null) {
    if (this._isHlsLoadCurrent(token)) return;
    this._destroyHlsInstance(hls);
    throw new StreamLoaderCancelledError();
  }

  _assertMpegtsLoadCurrent(token, player = null) {
    if (this._isMpegtsLoadCurrent(token)) return;
    this._destroyMpegtsInstance(player);
    throw new StreamLoaderCancelledError();
  }

  _destroyHlsInstance(hls) {
    if (!hls || this._destroyedHlsInstances.has(hls)) return;

    const engine = this.hlsEngine?.client === hls ? this.hlsEngine : null;
    if (engine) this.hlsEngine = null;

    this._destroyedHlsInstances.add(hls);
    try {
      if (engine) engine.destroy();
      else hls.destroy();
    } catch (error) {
      log.debug("[StreamLoader] HLS teardown failed:", error);
    }
  }
  _destroyMpegtsInstance() {
    this.mpegtsLoadGeneration += 1;

    const engine = this.mpegtsEngine;
    const player = this.mpegtsPlayer;
    this.mpegtsEngine = null;
    this.mpegtsPlayer = null;

    if (engine) {
      try {
        engine.destroy();
      } catch {
        // Teardown stays best-effort during source transitions.
      }
      return;
    }

    if (!player) return;

    for (const method of ["pause", "unload", "detachMediaElement", "destroy"]) {
      try {
        player[method]?.();
      } catch {
        // Compatibility cleanup for instances created before the engine wrapper.
      }
    }
  }

  _bindHlsListeners(hls, hlsEngine, Hls, token, sessionId, lowLatencyTarget) {
    hls.on(Hls.Events.FRAG_LOADED, (_event, data) => {
      if (!this._isHlsLoadCurrent(token)) return;
      if (data.frag.stats.loaded && data.frag.stats.loading.end) {
        const loadTime = data.frag.stats.loading.end - data.frag.stats.loading.start;
        const bandwidth = (data.frag.stats.loaded * 8000) / loadTime;
        this.onFragLoaded(bandwidth, sessionId);
      }
    });

    hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
      if (!this._isHlsLoadCurrent(token)) return;
      if (lowLatencyTarget != null && "targetLatency" in hls) {
        hls.targetLatency = lowLatencyTarget;
        log.debug(`[StreamLoader] HLS target latency set to ${lowLatencyTarget}s`);
      }
      log.debug("HLS manifest parsed, levels:", data.levels.length);
      this.onManifestParsed(data, sessionId);
    });

    hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
      if (!this._isHlsLoadCurrent(token)) return;
      this.onLevelSwitched(data.level, hls.levels[data.level], sessionId);
    });

    hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => {
      if (!this._isHlsLoadCurrent(token)) return;
      this.onAudioTracksUpdated(hlsEngine.getAudioTracks?.() ?? [], sessionId);
    });

    hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, () => {
      if (!this._isHlsLoadCurrent(token)) return;
      this.onSubtitleTracksUpdated(hlsEngine.getSubtitleTracks?.() ?? [], sessionId);
    });

    hls.on(Hls.Events.ERROR, (_event, data) => {
      if (!this._isHlsLoadCurrent(token)) return;
      log.error("HLS error:", data);
      this.onError("hls", data, sessionId);
    });
  }

  _bindMpegtsListeners(player, mpegts, token, sessionId) {
    player.on(mpegts.Events.STATISTICS_INFO, (info) => {
      if (this._isMpegtsLoadCurrent(token) && info.speed) {
        this.onStatisticsInfo(info.speed * 1000, sessionId);
      }
    });

    player.on(mpegts.Events.MEDIA_INFO, (info) => {
      if (!this._isMpegtsLoadCurrent(token)) return;
      log.debug("MPEG-TS media info:", info);
      this.onMediaInfo(info, sessionId);
    });

    player.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
      if (!this._isMpegtsLoadCurrent(token)) return;
      log.error("MPEG-TS error:", errorType, errorDetail, errorInfo);
      this.onError("mpegts", { errorType, errorDetail, errorInfo }, sessionId);
    });
  }

  /**
   * Load HLS stream (async - lazy loads hls.js on first call)
   */
  async loadHls(url) {
    log.debug("Loading HLS:", url);
    if (this.disposed) throw new StreamLoaderCancelledError();
    const token = ++this._hlsLoadToken;
    const sessionId = this.sessionId;
    if (this.hls) {
      const previousHls = this.hls;
      this.hls = null;
      this._destroyHlsInstance(previousHls);
    }

    const Hls = await this._dependencies.getHls();
    this._assertHlsLoadCurrent(token);
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

    const hls = new Hls({
      ...hlsConfig,
      xhrSetup: (xhr) => {
        xhr.withCredentials = false;
      },
    });
    const hlsEngine = this._dependencies.createHlsPlaybackEngine({
      video: this.video,
      hls,
      resetSourceOnDestroy: false,
    });

    this._bindHlsListeners(hls, hlsEngine, Hls, token, sessionId, lowLatencyTarget);
    this._assertHlsLoadCurrent(token, hls);
    this.hls = hls;
    this.hlsEngine = hlsEngine;

    try {
      hlsEngine.load(url);
      this._assertHlsLoadCurrent(token, hls);
    } catch (error) {
      if (this.hls === hls) this.hls = null;
      this._destroyHlsInstance(hls);
      throw error;
    }

    // Initialize Adaptive Buffer Manager for ADAPTIVE mode
    if (this.streamingMode === StreamingMode.ADAPTIVE && adaptiveConfig) {
      try {
        const AdaptiveBufferManager = await this._dependencies.getAdaptiveBufferManager();
        this._assertHlsLoadCurrent(token, hls);
        const manager = new AdaptiveBufferManager(hls, adaptiveConfig);
        this._assertHlsLoadCurrent(token, hls);
        this.adaptiveBufferManager = manager;
        manager.start();
        log.info("[StreamLoader] Adaptive buffer management enabled");
      } catch (e) {
        if (isStreamLoaderCancelledError(e)) throw e;
        log.warn("[StreamLoader] Failed to load adaptive buffer manager:", e.message);
      }
    }

    this._assertHlsLoadCurrent(token, hls);
    return hls;
  }

  /**
   * Load MPEG-TS stream (async - lazy loads mpegts.js on first call)
   */
  async loadMpegts(url, type = "mpegts") {
    log.debug("Loading MPEG-TS:", url, "type:", type);
    if (this.disposed) throw new StreamLoaderCancelledError();
    const token = ++this._mpegtsLoadToken;
    const sessionId = this.sessionId;
    if (this.mpegtsPlayer) {
      const previousPlayer = this.mpegtsPlayer;
      this.mpegtsPlayer = null;
      this._destroyMpegtsInstance(previousPlayer);
    }

    const mpegts = await this._dependencies.getMpegts();
    this._assertMpegtsLoadCurrent(token);
    this._mpegts = mpegts;

    const config = getStreamingConfig(this.streamingMode);

    const player = mpegts.createPlayer(
      {
        type: type,
        isLive: this.contentType === "live",
        url: url,
      },
      config.mpegts,
    );

    const engine = createMpegtsPlaybackEngine({
      video: this.video,
      player,
      source: { url, type },
      resetSourceOnDestroy: false,
    });

    this._bindMpegtsListeners(player, mpegts, token, sessionId);
    this._assertMpegtsLoadCurrent(token, player);
    this.mpegtsPlayer = player;
    this.mpegtsEngine = engine;

    try {
      this._assertMpegtsLoadCurrent(token, player);
      engine.load({ url, type });
      this._assertMpegtsLoadCurrent(token, player);
    } catch (error) {
      if (this.mpegtsPlayer === player) this.mpegtsPlayer = null;
      this._destroyMpegtsInstance(player);
      throw error;
    }

    return player;
  }

  /**
   * Soft reload HLS stream (reuses existing player instance)
   * Returns true if soft reload was used, false if full reload needed
   */
  async loadHlsSoft(url) {
    if (this.disposed) throw new StreamLoaderCancelledError();
    if (!this.hls || !this.hlsEngine) {
      log.debug("No existing HLS engine, using full load");
      return this.loadHls(url);
    }

    log.debug("Soft reloading HLS:", url);
    const hls = this.hlsEngine.reload(url);
    if (this.disposed) throw new StreamLoaderCancelledError();

    return hls;
  }

  /**
   * Soft reload MPEG-TS stream (reuses existing player instance)
   * Returns player instance
   */
  async loadMpegtsSoft(url, type = "mpegts") {
    if (!this.mpegtsEngine) return this.loadMpegts(url, type);

    const generation = this.mpegtsLoadGeneration;
    this._assertMpegtsLoadCurrent(generation);
    this.mpegtsEngine.reload({ url, type });
    this._assertMpegtsLoadCurrent(generation);

    return { status: "loaded", engine: this.mpegtsEngine };
  }
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
   * Get the contract-compliant HLS playback engine.
   */
  getHlsEngine() {
    return this.hlsEngine;
  }

  /**
   * Get MPEG-TS player instance
   */
  getMpegtsPlayer() {
    return this.mpegtsPlayer;
  }

  getMpegtsEngine() {
    return this.mpegtsEngine;
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
    return this.hlsEngine?.selectAudioTrack?.(trackIndex) ?? false;
  }

  /**
   * Set subtitle track (HLS only)
   */
  setSubtitleTrack(trackIndex) {
    return this.hlsEngine?.selectSubtitleTrack?.(trackIndex) ?? false;
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
    if (this.disposed) return;
    this.disposed = true;
    this._hlsLoadToken += 1;
    this._mpegtsLoadToken += 1;

    // Stop adaptive buffer manager first
    if (this.adaptiveBufferManager) {
      try {
        this.adaptiveBufferManager.stop();
      } catch (error) {
        log.debug("[StreamLoader] Adaptive buffer teardown failed:", error);
      }
      this.adaptiveBufferManager = null;
    }

    if (this.hls) {
      this._destroyHlsInstance(this.hls);
      this.hls = null;
    }

    if (this.mpegtsPlayer) {
      this._destroyMpegtsInstance(this.mpegtsPlayer);
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
