import { getHls, getMpegts, isHlsJsSupported, isMpegtsSupported } from "../lib/player_libs";
import { getCapabilitySummary, getCodecCapabilityReport } from "../lib/codec_detector";
import { CodecAwareABR, getCodecRecommendation, selectOptimalQuality } from "../lib/codec_priority";
import { createErrorReport, detectErrorPatterns, formatErrorForLog } from "../lib/error_telemetry";
import { KeyboardManager } from "../lib/keyboard_manager";
import { playerLogger as log, setErrorReporter } from "../lib/logger";
import { NetworkMonitor } from "../lib/network_monitor";
import { diagnoseError, runQuickDiagnostics } from "../lib/player_diagnostics";
import {
  getPlaybackPosition,
  getPreferences,
  getRecommendedPlayer,
  recordPlayerSuccess,
  saveAudioTrack,
  saveMuted,
  savePlaybackPosition,
  savePlaybackRate,
  savePreferAVPlayer,
  saveSubtitleTrack,
  saveVolume,
} from "../lib/player_preferences";
import { PlayerUI } from "../lib/player_ui";
import { NativeBufferManager } from "../lib/native_buffer";
import { getFileExtension, getStreamType, StreamLoader } from "../lib/stream_loader";
import {
  ContentType,
  FeatureFlags,
  getCodecOptimizedConfig,
  getFeatureRecommendations,
  getStreamingConfig,
  selectStreamingMode,
} from "../lib/streaming_config";
import { linearToPerceived, perceivedToLinear } from "../lib/volume_utils";
import { getWebCodecsCapabilityReport, isWebCodecsSupported } from "../lib/webcodecs_decoder";
import { getMSEWorkerCapabilityReport, isMSEInWorkersSupported } from "../lib/worker_mse";

// Lazy load AVPlayer only when needed
let AVPlayerWrapper = null;
let detectAudioIssue = null;
let preloadCommonWasm = null;

async function loadAVPlayer() {
  if (!AVPlayerWrapper) {
    log.debug("Lazy loading AVPlayer module...");
    const module = await import("../lib/avplayer_wrapper");
    AVPlayerWrapper = module.AVPlayerWrapper;
    detectAudioIssue = module.detectAudioIssue;
    preloadCommonWasm = module.preloadCommonWasm;
    log.debug("AVPlayer module loaded");
  }
  return { AVPlayerWrapper, detectAudioIssue, preloadCommonWasm };
}

function isFirefoxBrowser() {
  return /firefox/i.test(navigator.userAgent);
}

// Advanced WASM pre-loading with WebAssembly.compile for faster startup
let wasmPreloaded = false;
async function preloadAVPlayerWasm() {
  if (wasmPreloaded) return;
  wasmPreloaded = true;

  try {
    // Load module and use advanced pre-loading with WebAssembly.compile
    const { preloadCommonWasm } = await loadAVPlayer();
    if (preloadCommonWasm) {
      log.debug("Starting advanced WASM pre-compilation...");
      await preloadCommonWasm();
      log.debug("WASM pre-compilation complete");
    }
  } catch (e) {
    log.debug("WASM pre-load failed (non-critical):", e.message);
    // Fallback to simple prefetch
    const wasmFiles = [
      "/avplayer/decode/h264-atomic.wasm",
      "/avplayer/decode/ac3-atomic.wasm",
      "/avplayer/decode/aac-atomic.wasm",
    ];
    wasmFiles.forEach((url) => {
      const link = document.createElement("link");
      link.rel = "prefetch";
      link.href = url;
      link.as = "fetch";
      link.crossOrigin = "anonymous";
      document.head.appendChild(link);
    });
  }
}

/**
 * Enhanced VideoPlayer Hook for Streamix
 *
 * Features:
 * - Multi-codec support (HLS, MPEG-TS, FLV, MP4)
 * - Adaptive streaming with dynamic mode switching
 * - Quality selection (auto + manual levels)
 * - Audio/subtitle track selection
 * - Picture-in-Picture support
 * - Network monitoring with automatic adaptation
 * - Progress tracking for VOD content
 * - Preferences persistence (volume, tracks)
 * - Keyboard shortcuts (YouTube-style)
 * - Circuit breaker for fallback loops
 */
const VideoPlayer = {
  mounted() {
    this.initializeState();
    this.loadPreferences();
    this.initUI();
    this.initPlayer();
    this.setupEventListeners();
    this.setupNetworkMonitor();
    this.setupKeyboardShortcuts();
    this.trackWatchTime();

    // Configure error reporter to send errors to backend
    setErrorReporter((event, data) => this.pushEvent(event, data));

    // Expose hook instance on element for child hooks (like ProgressBar) to access
    this.el.__videoPlayerHook = this;

    // Smart preloading based on Device Codec Memory and content type
    this.smartPreload();

    // Run quick diagnostics in background (non-blocking)
    this.runStartupDiagnostics();
  },

  /**
   * Smart preloading based on past experience and content type
   * Netflix pattern: pre-load resources before they're needed
   */
  smartPreload() {
    const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
    const recommendedPlayer = getRecommendedPlayer(contentKey);

    // Pre-load AVPlayer if:
    // 1. Device Codec Memory recommends it
    // 2. Manual preference is set
    // 3. GIndex/MKV content (likely needs AVPlayer for audio)
    const shouldPreloadAVPlayer =
      recommendedPlayer === "avplayer" ||
      this.preferAVPlayer ||
      this.sourceType === "gindex" ||
      this.currentStreamType === "mkv";

    if (shouldPreloadAVPlayer) {
      log.debug("[VideoPlayer] Smart preload: AVPlayer WASM");
      preloadAVPlayerWasm();
    }
  },

  /**
   * Run quick diagnostics at startup (non-blocking)
   * Helps detect issues early and inform backend of device capabilities
   */
  async runStartupDiagnostics() {
    try {
      const quickDiag = await runQuickDiagnostics();

      if (!quickDiag.allPassed) {
        log.warn(
          "[VideoPlayer] Some startup diagnostics failed:",
          quickDiag.results.filter((r) => !r.passed),
        );
      }

      // Detect advanced capabilities
      const advancedCapabilities = await this.detectAdvancedCapabilities();

      // Send capabilities to backend for analytics
      this.pushEvent("device_diagnostics", {
        quick: quickDiag,
        capabilities: getCapabilitySummary(),
        advanced: advancedCapabilities,
      });

      // Initialize codec-aware ABR if supported
      if (advancedCapabilities.codecRecommendation) {
        this.initCodecAwareABR(advancedCapabilities.codecRecommendation);
      }
    } catch (e) {
      log.debug("[VideoPlayer] Startup diagnostics failed (non-critical):", e);
    }
  },

  /**
   * Detect advanced streaming capabilities
   * WebCodecs, MSE Workers, codec priority
   */
  async detectAdvancedCapabilities() {
    const capabilities = {
      webCodecs: {
        supported: isWebCodecsSupported(),
        report: null,
      },
      mseWorkers: {
        supported: isMSEInWorkersSupported(),
        report: getMSEWorkerCapabilityReport(),
      },
      codecRecommendation: null,
      featureRecommendations: null,
    };

    // Get detailed WebCodecs report if supported
    if (capabilities.webCodecs.supported) {
      try {
        capabilities.webCodecs.report = await getWebCodecsCapabilityReport();
        log.debug("[VideoPlayer] WebCodecs available:", capabilities.webCodecs.report);
      } catch (e) {
        log.debug("[VideoPlayer] WebCodecs report failed:", e.message);
      }
    }

    // Get codec recommendation
    try {
      const networkInfo = navigator.connection;
      capabilities.codecRecommendation = await getCodecRecommendation({
        networkQuality: this.getNetworkQualityFromInfo(networkInfo),
        deviceMemory: navigator.deviceMemory || 4,
        cpuCores: navigator.hardwareConcurrency || 4,
      });
      log.debug("[VideoPlayer] Codec recommendation:", capabilities.codecRecommendation);
    } catch (e) {
      log.debug("[VideoPlayer] Codec recommendation failed:", e.message);
    }

    // Get feature recommendations
    try {
      const fullReport = await getCodecCapabilityReport();
      capabilities.featureRecommendations = getFeatureRecommendations(fullReport);
      log.debug("[VideoPlayer] Feature recommendations:", capabilities.featureRecommendations);

      // Log experimental feature availability
      if (capabilities.featureRecommendations.useWebCodecs) {
        log.debug("[VideoPlayer] WebCodecs hardware acceleration available");
      }
      if (capabilities.featureRecommendations.useMSEWorkers) {
        log.debug("[VideoPlayer] MSE in Workers available - smoother UI during buffering");
      }
      if (capabilities.featureRecommendations.preferAV1) {
        log.debug("[VideoPlayer] AV1 codec available - 30% bandwidth savings possible");
      }
    } catch (e) {
      log.debug("[VideoPlayer] Feature recommendations failed:", e.message);
    }

    return capabilities;
  },

  /**
   * Convert Network Information API data to quality string
   */
  getNetworkQualityFromInfo(networkInfo) {
    if (!networkInfo) return "good";

    const effectiveType = networkInfo.effectiveType;
    switch (effectiveType) {
      case "slow-2g":
      case "2g":
        return "poor";
      case "3g":
        return "good";
      case "4g":
        return "excellent";
      default:
        return "good";
    }
  },

  /**
   * Initialize codec-aware ABR controller
   */
  initCodecAwareABR(recommendation) {
    if (!FeatureFlags.advancedABR.enabled) return;

    this.codecABR = new CodecAwareABR({
      initialCodec: recommendation.codec,
      safetyFactor: FeatureFlags.advancedABR.safetyFactor,
    });

    log.debug("[VideoPlayer] Codec-aware ABR initialized with", recommendation.codec);
  },

  initializeState() {
    // DOM elements
    this.video = this.el.querySelector("video");

    // Stream configuration
    this.streamUrl = this.el.dataset.streamUrl;
    this.proxyUrl = this.el.dataset.proxyUrl;
    this.contentType = this.el.dataset.contentType || "live";
    this.sourceType = this.el.dataset.sourceType || null;
    this.contentId = this.el.dataset.contentId;
    this.initialMode = this.el.dataset.streamingMode || null;
    this.expectedDuration = parseInt(this.el.dataset.expectedDuration, 10) || 0;

    // Player instances
    this.streamLoader = null;
    this.hls = null;
    this.mpegtsPlayer = null;

    // Streaming state
    this.streamingMode =
      this.initialMode ||
      selectStreamingMode(this.contentType === "live" ? ContentType.LIVE : ContentType.VOD, "good");
    this.currentStreamType = null;
    this.currentUrl = null;

    // Quality state
    this.manualQuality = null;
    this.availableQualities = [];

    // Track state
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.selectedAudioTrack = 0;
    this.selectedSubtitleTrack = -1;

    // Retry/fallback state with circuit breaker (exponential backoff)
    this.retryCount = 0;
    this.maxRetries = 3;
    this.useProxy = true;
    this.fallbackAttempts = 0;
    this.maxFallbackAttempts = 5; // Circuit breaker limit
    this.lastFallbackTime = 0;
    this.fallbackCooldowns = [2000, 5000, 10000, 20000, 30000]; // Exponential backoff delays

    // Timing
    this.startTime = Date.now();
    this.lastProgressReport = 0;

    // PiP state
    this.pipActive = false;

    // Network monitor
    this.networkMonitor = null;

    // Keyboard manager
    this.keyboardManager = null;

    // AVPlayer fallback state
    this.avPlayer = null;
    this.usingAVPlayer = false;
    this.audioCheckTimeout = null;
    this.avPlayerAttempted = false;
    this.avPlayerVolume = 1;
    this.avPlayerMuted = false;
    this.avPlayerTimeInterval = null;
    this.preferAVPlayer = false; // Manual audio compatibility mode

    // Next episode state (for pre-fetch)
    this.nextEpisode = this.parseNextEpisode();
    this.nextEpisodeShown = false;
    this.nextEpisodeCountdown = null;
    this.nextEpisodePreloader = null;

    // Advanced features state
    this.codecABR = null; // Codec-aware ABR controller
    this.advancedCapabilities = null; // Cached advanced capabilities
    this.preferredCodec = null; // User/auto selected codec preference

    // Native buffer manager (for MP4/MKV streams)
    this.nativeBufferManager = null;
  },

  /**
   * Parse next episode data from data attribute
   */
  parseNextEpisode() {
    const data = this.el.dataset.nextEpisode;
    if (!data) return null;
    try {
      return JSON.parse(data);
    } catch {
      log.warn("[VideoPlayer] Failed to parse next episode data");
      return null;
    }
  },

  loadPreferences() {
    const prefs = getPreferences(this.contentId);

    // Apply volume (prefs.volume is UI value, convert to perceived for backends)
    this.avPlayerVolume = prefs.volume;
    this.avPlayerMuted = prefs.muted;
    if (this.video) {
      this.video.volume = linearToPerceived(prefs.volume);
      this.video.muted = prefs.muted;
    }

    // Store track preferences to apply after manifest loads
    this._preferredAudioTrack = prefs.audioTrack;
    this._preferredSubtitleTrack = prefs.subtitleTrack;

    // Playback rate
    if (this.video && prefs.playbackRate !== 1) {
      this.video.playbackRate = prefs.playbackRate;
    }

    // Manual AVPlayer preference
    this.preferAVPlayer = prefs.preferAVPlayer;

    // Load saved playback position for VOD content
    if (this.contentType === "vod" && this.contentId) {
      this._savedPosition = getPlaybackPosition(this.contentId);
      if (this._savedPosition) {
        log.debug("Found saved position:", this._savedPosition.time, "seconds");
      }
    }
  },

  initUI() {
    this.playerUI = new PlayerUI(this.el);

    // Setup retry button
    const retryBtn = this.el.querySelector(".retry-btn");
    if (retryBtn) {
      retryBtn.addEventListener("click", () => {
        this.playerUI.hideError();
        this.retryCount = 0;
        this.fallbackAttempts = 0;
        this.initPlayer();
      });
    }
  },

  // ============================================
  // Network Monitoring
  // ============================================

  setupNetworkMonitor() {
    this.networkMonitor = new NetworkMonitor({
      onQualityChange: (newQuality, oldQuality, stats) => {
        log.debug(`Network quality changed: ${oldQuality} -> ${newQuality}`, stats);

        if (this.manualQuality === null && this.contentType === "live") {
          const newMode = selectStreamingMode(ContentType.LIVE, newQuality);
          if (newMode !== this.streamingMode) {
            this.switchStreamingMode(newMode);
          }
        }
      },
    });

    this.networkMonitor.start();
  },

  // ============================================
  // Streaming Mode Management
  // ============================================

  switchStreamingMode(newMode) {
    if (newMode === this.streamingMode) return;

    log.debug(`Switching streaming mode: ${this.streamingMode} -> ${newMode}`);
    this.streamingMode = newMode;

    if (this.streamLoader) {
      this.streamLoader.updateStreamingMode(newMode);
    }

    this.pushEvent("streaming_mode_changed", {
      mode: newMode,
      config: getStreamingConfig(newMode).name,
    });
  },

  // ============================================
  // Quality Selection
  // ============================================

  setQuality(levelIndex) {
    if (this.streamLoader) {
      // Use codec-aware ABR for auto quality selection
      if (levelIndex === -1 && this.codecABR && FeatureFlags.advancedABR.enabled) {
        const suggestion = this.codecABR.suggestQuality(this.availableQualities);
        log.debug("[VideoPlayer] Codec ABR suggests:", suggestion.reason);
        // Let HLS.js handle auto, but log the suggestion
        this.pushEvent("codec_abr_suggestion", {
          suggestedLevel: suggestion.levelIndex,
          reason: suggestion.reason,
        });
      }
      this.streamLoader.setQuality(levelIndex);
    }
    this.manualQuality = levelIndex === -1 ? null : levelIndex;

    const quality =
      levelIndex === -1
        ? "auto"
        : this.availableQualities[levelIndex]?.label || `Level ${levelIndex}`;

    this.pushEvent("quality_changed", { quality, level: levelIndex });
  },

  updateQualityList() {
    if (!this.streamLoader) return;

    this.availableQualities = this.streamLoader.getQualityLevels();
    const currentLevel = this.streamLoader.getCurrentLevel();

    // Enhance quality list with codec information
    const enhancedQualities = this.availableQualities.map((q) => ({
      ...q,
      codec: this.detectQualityCodec(q),
    }));

    this.playerUI.updateQualityOptions(enhancedQualities, currentLevel, (level) =>
      this.setQuality(level),
    );

    // Include codec info in event
    this.pushEvent("qualities_available", {
      qualities: [{ index: -1, label: "Automatico" }, ...enhancedQualities],
      current: currentLevel,
      codecABREnabled: !!this.codecABR,
    });

    // Update codec ABR with current codec if available
    if (this.codecABR && enhancedQualities.length > 0 && currentLevel >= 0) {
      const currentQuality = enhancedQualities[currentLevel];
      if (currentQuality?.codec) {
        this.codecABR.setCodec(currentQuality.codec);
      }
    }
  },

  /**
   * Detect codec from quality level
   */
  detectQualityCodec(quality) {
    const codecs = quality.videoCodec || quality.codecs || "";
    if (codecs.includes("av01") || codecs.includes("av1")) return "av1";
    if (codecs.includes("hvc1") || codecs.includes("hev1") || codecs.includes("hevc")) return "hevc";
    if (codecs.includes("vp09") || codecs.includes("vp9")) return "vp9";
    if (codecs.includes("avc1") || codecs.includes("h264")) return "h264";
    return "unknown";
  },

  // ============================================
  // Audio Track Selection
  // ============================================

  setAudioTrack(trackIndex) {
    if (this.streamLoader) {
      this.streamLoader.setAudioTrack(trackIndex);
    }
    this.selectedAudioTrack = trackIndex;

    // Save preference
    saveAudioTrack(trackIndex, this.contentId);

    const track = this.audioTracks[trackIndex];
    this.pushEvent("audio_track_changed", {
      track: trackIndex,
      label: track?.name || track?.lang || `Track ${trackIndex}`,
    });
  },

  updateAudioTracks() {
    const hls = this.streamLoader?.getHls();
    if (!hls) return;

    this.audioTracks = hls.audioTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Audio ${index + 1}`,
    }));

    const currentTrack = hls.audioTrack;

    this.playerUI.updateAudioOptions(this.audioTracks, currentTrack, (track) =>
      this.setAudioTrack(track),
    );

    // Apply saved preference
    if (this._preferredAudioTrack !== null && this._preferredAudioTrack < this.audioTracks.length) {
      this.setAudioTrack(this._preferredAudioTrack);
    }

    this.pushEvent("audio_tracks_available", {
      tracks: this.audioTracks,
      current: currentTrack,
    });
  },

  // ============================================
  // Subtitle Track Selection
  // ============================================

  setSubtitleTrack(trackIndex) {
    if (this.streamLoader) {
      this.streamLoader.setSubtitleTrack(trackIndex);
    }
    this.selectedSubtitleTrack = trackIndex;

    // Save preference
    saveSubtitleTrack(trackIndex, this.contentId);

    const track = trackIndex >= 0 ? this.subtitleTracks[trackIndex] : null;
    this.pushEvent("subtitle_track_changed", {
      track: trackIndex,
      label:
        track?.name || track?.lang || (trackIndex === -1 ? "Desativado" : `Faixa ${trackIndex}`),
    });
  },

  updateSubtitleTracks() {
    const hls = this.streamLoader?.getHls();
    if (!hls) return;

    this.subtitleTracks = hls.subtitleTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Legenda ${index + 1}`,
    }));

    const currentTrack = hls.subtitleTrack;

    this.playerUI.updateSubtitleOptions(this.subtitleTracks, currentTrack, (track) =>
      this.setSubtitleTrack(track),
    );

    // Apply saved preference
    if (
      this._preferredSubtitleTrack !== null &&
      this._preferredSubtitleTrack < this.subtitleTracks.length
    ) {
      this.setSubtitleTrack(this._preferredSubtitleTrack);
    }

    this.pushEvent("subtitle_tracks_available", {
      tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
      current: currentTrack,
    });
  },

  // ============================================
  // Picture-in-Picture
  // ============================================

  async togglePiP() {
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
        this.pipActive = false;
      } else if (document.pictureInPictureEnabled && this.video) {
        await this.video.requestPictureInPicture();
        this.pipActive = true;
      }

      this.pushEvent("pip_toggled", { active: this.pipActive });
    } catch (error) {
      console.error("PiP error:", error);
      this.pushEvent("pip_error", { message: error.message });
    }
  },

  isPiPSupported() {
    return document.pictureInPictureEnabled && !this.video?.disablePictureInPicture;
  },

  // ============================================
  // Event Listeners
  // ============================================

  setupEventListeners() {
    // DOM Custom Events from UI Controls
    this.el.addEventListener("player:toggle-play", () => this.togglePlayPause());
    this.el.addEventListener("player:toggle-mute", () => this.toggleMute());
    this.el.addEventListener("player:toggle-fullscreen", () => this.toggleFullscreen());
    this.el.addEventListener("player:toggle-pip", () => this.togglePiP());
    this.el.addEventListener("player:set-speed", (e) => {
      const speed = parseFloat(e.detail?.speed || 1);
      this.setPlaybackRate(speed);
    });
    this.el.addEventListener("player:toggle-avplayer", () => this.toggleAVPlayerPreference());

    // Mobile Touch Support
    this.setupMobileControls();

    // Volume slider input
    const volumeSlider = this.el.querySelector("#volume-slider");
    if (volumeSlider) {
      volumeSlider.addEventListener("input", (e) => {
        const volume = parseInt(e.target.value, 10) / 100;
        this.setVolume(volume);
      });
    }

    // Video Element Events
    this.video?.addEventListener("play", () => this.playerUI.updatePlayPauseUI(false));
    this.video?.addEventListener("pause", () => this.playerUI.updatePlayPauseUI(true));
    this.video?.addEventListener("volumechange", () => this.updateVolumeUI());
    this.video?.addEventListener("timeupdate", () => {
      this.updateTimeUI();

      // Safety net: if video time is advancing, loading should be hidden
      // Fixes "infinite loading" on live streams where playing/canplaythrough don't re-fire
      if (this.video && !this.video.paused && this.video.readyState >= 3) {
        this.playerUI.hideLoading();
      }
    });
    this.video?.addEventListener("loadedmetadata", () => this.updateTimeUI());
    this.video?.addEventListener("ratechange", () =>
      this.playerUI.updateSpeedUI(this.video.playbackRate),
    );
    this.video?.addEventListener("progress", () => {
      this.updateBufferBar();

      // For live streams: if buffer is filling, stream is healthy → hide loading
      if (this.video && !this.video.paused && this.video.buffered.length > 0) {
        const bufferedEnd = this.video.buffered.end(this.video.buffered.length - 1);
        const bufferAhead = bufferedEnd - this.video.currentTime;
        if (bufferAhead > 1) {
          this.playerUI.hideLoading();
        }
      }
    });

    // Fullscreen events
    document.addEventListener("fullscreenchange", () =>
      this.playerUI.updateFullscreenUI(!!document.fullscreenElement),
    );
    document.addEventListener("webkitfullscreenchange", () =>
      this.playerUI.updateFullscreenUI(!!document.fullscreenElement),
    );

    // LiveView commands
    this.handleEvent("set_quality", ({ level }) => this.setQuality(level));
    this.handleEvent("set_audio_track", ({ track }) => this.setAudioTrack(track));
    this.handleEvent("set_subtitle_track", ({ track }) => this.setSubtitleTrack(track));
    this.handleEvent("toggle_pip", () => this.togglePiP());
    this.handleEvent("set_streaming_mode", ({ mode }) => this.switchStreamingMode(mode));
    this.handleEvent("seek", ({ time }) => this.seekTo(time));
    this.handleEvent("set_playback_rate", ({ rate }) => this.setPlaybackRate(rate));
    this.handleEvent("refresh_token", ({ url, proxyUrl }) => {
      // Handle token refresh from server
      log.debug("[VideoPlayer] Token refreshed, updating URLs");
      this.streamUrl = url;
      this.proxyUrl = proxyUrl;
      this.retryCount = 0;
      this.initPlayer();
    });

    // PiP events
    this.video?.addEventListener("enterpictureinpicture", () => {
      this.pipActive = true;
      this.pushEvent("pip_toggled", { active: true });
    });

    this.video?.addEventListener("leavepictureinpicture", () => {
      this.pipActive = false;
      this.pushEvent("pip_toggled", { active: false });
    });

    // Progress tracking for VOD
    if (this.contentType === "vod") {
      this.video?.addEventListener("timeupdate", () => this.reportProgress());
      this.video?.addEventListener("durationchange", () => {
        if (this.video.duration && Number.isFinite(this.video.duration)) {
          this.pushEvent("duration_available", {
            duration: Math.floor(this.video.duration),
          });
        }
      });
    }

    // Buffer health monitoring with debounce to prevent flickering
    this.video?.addEventListener("waiting", () => {
      // Debounce showing loading spinner (200ms) to avoid flickering on unstable networks
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
      }
      this._bufferingDebounce = setTimeout(() => {
        // Only show if still buffering
        if (this.video && !this.video.paused && this.video.readyState < 3) {
          this.playerUI.showLoading();
          this.pushEvent("buffering", { buffering: true });
        }
      }, 200);
    });

    this.video?.addEventListener("playing", () => {
      // Cancel any pending buffering indicator
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
        this._bufferingDebounce = null;
      }
      this.pushEvent("buffering", { buffering: false });
      this.playerUI.hideLoading();
      this.playerUI.hideError();
    });

    // Also hide loading on canplaythrough (video exits buffering during playback)
    // The "playing" event doesn't fire when video exits buffering if already playing
    this.video?.addEventListener("canplaythrough", () => {
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
        this._bufferingDebounce = null;
      }
      this.pushEvent("buffering", { buffering: false });
      this.playerUI.hideLoading();
    });
  },

  // ============================================
  // UI Update Helpers
  // ============================================

  updateVolumeUI() {
    let volume, muted;
    if (this.usingAVPlayer) {
      volume = this.avPlayerVolume;
      muted = this.avPlayerMuted;
    } else {
      // Convert perceived volume back to linear for UI display
      // This prevents the slider from "jumping" when reading from video.volume
      const rawVolume = this.video?.volume ?? 1;
      volume = perceivedToLinear(rawVolume);
      muted = this.video?.muted || false;
    }
    this.playerUI.updateVolumeUI(volume, muted);
  },

  updateTimeUI() {
    const currentTime = this.getCurrentTime();
    const duration = this.getDuration();
    this.playerUI.updateTimeUI(currentTime, duration);
  },

  updateBufferBar() {
    if (this.video?.buffered) {
      this.playerUI.updateBufferBar(
        this.video.buffered,
        this.video.duration,
        this.video.currentTime,
      );
    }
  },

  /**
   * Show error with optional automatic diagnostics (Netflix pattern)
   * @param {string} message - Error message to display
   * @param {Error|string} error - Original error for diagnostics
   * @param {boolean} runDiagnostics - Whether to run automatic diagnostics
   */
  async showErrorWithDiagnostics(message, error = null, runDiagnostics = false) {
    this.playerUI.showError(message);

    if (runDiagnostics && error) {
      try {
        const diagnosis = await diagnoseError(error, {
          contentType: this.contentType,
          streamType: this.currentStreamType,
          sourceType: this.sourceType,
        });

        log.debug("[VideoPlayer] Diagnostics result:", diagnosis);

        // If we have a suggested player, offer to try it
        if (diagnosis.suggestedPlayer?.player && diagnosis.suggestedPlayer.player !== "native") {
          this.pushEvent("diagnostic_suggestion", {
            player: diagnosis.suggestedPlayer.player,
            reason: diagnosis.suggestedPlayer.reason,
            recommendations: diagnosis.recommendations,
          });
        }
      } catch (e) {
        log.warn("[VideoPlayer] Diagnostics failed:", e);
      }
    }
  },

  setVolume(volume) {
    // Apply logarithmic curve for perceived loudness consistency
    const perceivedVolume = linearToPerceived(volume);

    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayerVolume = volume; // Store UI value
      if (volume > 0 && this.avPlayerMuted) {
        this.avPlayerMuted = false;
      }
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : perceivedVolume);
    } else if (this.video) {
      this.video.volume = perceivedVolume;
      if (volume > 0 && this.video.muted) {
        this.video.muted = false;
      }
    }
    saveVolume(volume); // Save UI value for consistency
    this.updateVolumeUI();
  },

  setPlaybackRate(rate) {
    if (this.video) {
      this.video.playbackRate = rate;
      savePlaybackRate(rate);
      this.pushEvent("playback_rate_changed", { rate });
    }
  },

  reportProgress() {
    const currentTime = Math.floor(this.getCurrentTime());
    const duration = Math.floor(this.getDuration());

    if (!duration || duration <= 0) return;

    // Check for next episode trigger (30s before end or 90% progress)
    this.checkNextEpisodeTrigger(currentTime, duration);

    if (Math.abs(currentTime - this.lastProgressReport) >= 10) {
      this.lastProgressReport = currentTime;

      // Save position to localStorage for resume later
      if (this.contentId && this.contentType === "vod") {
        savePlaybackPosition(this.contentId, currentTime, duration);
      }

      this.pushEvent("progress_update", {
        current_time: currentTime,
        duration: duration,
        percent: Math.round((currentTime / duration) * 100),
      });
    }
  },

  // ============================================
  // Next Episode Pre-fetch (Netflix-style)
  // ============================================

  /**
   * Check if we should show the next episode overlay
   * Triggers at 30 seconds before end OR 90% progress (whichever comes first)
   */
  checkNextEpisodeTrigger(currentTime, duration) {
    if (!this.nextEpisode || this.nextEpisodeShown) return;

    const timeRemaining = duration - currentTime;
    const percentComplete = (currentTime / duration) * 100;

    // Trigger at 30s before end or 90% progress
    const shouldTrigger = timeRemaining <= 30 || percentComplete >= 90;

    if (shouldTrigger) {
      this.showNextEpisodeOverlay();
      try {
        this.preloadNextEpisode();
      } catch (e) {
        log.debug("[VideoPlayer] Next episode preload error:", e.message);
      }
    }
  },

  /**
   * Show the next episode overlay with countdown
   */
  showNextEpisodeOverlay() {
    if (this.nextEpisodeShown) return;
    this.nextEpisodeShown = true;

    const overlay = this.el.querySelector("#next-episode-overlay");
    if (!overlay) return;

    // Show overlay with animation
    overlay.classList.remove("hidden");
    requestAnimationFrame(() => {
      overlay.classList.add("opacity-100");
      overlay.classList.remove("translate-x-4");
    });

    // Setup button handlers
    const playBtn = overlay.querySelector("#play-next-btn");
    const cancelBtn = overlay.querySelector("#cancel-next-btn");
    const countdownBar = overlay.querySelector("#next-countdown-bar");

    if (playBtn) {
      playBtn.onclick = () => {
        try {
          this.playNextEpisode();
        } catch (e) {
          log.debug("[VideoPlayer] playNextEpisode error:", e.message);
        }
      };
    }

    if (cancelBtn) {
      cancelBtn.onclick = () => this.hideNextEpisodeOverlay();
    }

    // Start 10-second countdown
    let countdown = 10;
    this.nextEpisodeCountdown = setInterval(() => {
      countdown--;
      if (countdownBar) {
        countdownBar.style.width = `${countdown * 10}%`;
      }
      if (countdown <= 0) {
        try {
          this.playNextEpisode();
        } catch (e) {
          log.debug("[VideoPlayer] playNextEpisode countdown error:", e.message);
        }
      }
    }, 1000);

    log.debug("[VideoPlayer] Showing next episode overlay:", this.nextEpisode.title);
  },

  /**
   * Hide the next episode overlay
   */
  hideNextEpisodeOverlay() {
    if (this.nextEpisodeCountdown) {
      clearInterval(this.nextEpisodeCountdown);
      this.nextEpisodeCountdown = null;
    }

    const overlay = this.el.querySelector("#next-episode-overlay");
    if (overlay) {
      overlay.classList.remove("opacity-100");
      overlay.classList.add("translate-x-4");
      setTimeout(() => overlay.classList.add("hidden"), 300);
    }

    // Cleanup preloader
    if (this.nextEpisodePreloader) {
      this.nextEpisodePreloader.destroy?.();
      this.nextEpisodePreloader = null;
    }
  },

  /**
   * Navigate to next episode
   */
  playNextEpisode() {
    if (!this.nextEpisode) return;

    this.hideNextEpisodeOverlay();

    // Whitelist validation to prevent path traversal
    const ALLOWED_TYPES = ["episode", "movie", "live"];
    const type = ALLOWED_TYPES.includes(this.nextEpisode.type) ? this.nextEpisode.type : "episode";

    // Validate ID is numeric to prevent injection
    const id = parseInt(this.nextEpisode.id, 10);
    if (Number.isNaN(id) || id <= 0) {
      log.warn("[VideoPlayer] Invalid next episode ID:", this.nextEpisode.id);
      return;
    }

    const path = `/watch/${type}/${id}`;

    log.debug("[VideoPlayer] Navigating to next episode:", path);

    // Navigate via direct URL (pushEvent is for server events, not navigation)
    window.location.href = path;
  },

  /**
   * Pre-load next episode stream for instant playback
   * Uses HLS.js to pre-fetch manifest and first segments
   */
  preloadNextEpisode() {
    if (!this.nextEpisode?.stream_url || this.nextEpisodePreloader) return;

    const url = this.nextEpisode.stream_url;
    log.debug("[VideoPlayer] Pre-loading next episode:", url);

    // Add preconnect hint for the stream domain
    try {
      const streamDomain = new URL(url).origin;
      const preconnect = document.createElement("link");
      preconnect.rel = "preconnect";
      preconnect.href = streamDomain;
      preconnect.crossOrigin = "anonymous";
      document.head.appendChild(preconnect);
    } catch (_e) {
      // Ignore URL parsing errors
    }

    // Pre-load with HLS.js if it's an HLS stream
    const streamType = getStreamType(url, this.nextEpisode.type);
    if (streamType === "hls" && isHlsJsSupported()) {
      getHls().then((Hls) => {
        this.nextEpisodePreloader = new Hls({
          // Minimal config for preloading only manifest + first segment
          maxBufferLength: 5,
          maxBufferSize: 1 * 1024 * 1024, // 1MB max
          maxMaxBufferLength: 5,
          startLevel: -1, // Auto quality
          enableWorker: true,
          lowLatencyMode: false,
        });

        // Don't attach to video element, just load manifest
        this.nextEpisodePreloader.loadSource(url);

        this.nextEpisodePreloader.on(Hls.Events.MANIFEST_PARSED, () => {
          log.debug("[VideoPlayer] Next episode manifest pre-loaded");
        });

        this.nextEpisodePreloader.on(Hls.Events.ERROR, (_, data) => {
          if (data.fatal) {
            log.warn("[VideoPlayer] Next episode preload failed:", data.type);
            this.nextEpisodePreloader?.destroy();
            this.nextEpisodePreloader = null;
          }
        });
      }).catch((e) => {
        log.debug("[VideoPlayer] Failed to preload next episode:", e.message);
      });
    }
  },

  // ============================================
  // URL Handling
  // ============================================

  getEffectiveUrl(streamType) {
    const isHttpUrl = this.streamUrl?.startsWith("http://");
    const isHttpsPage = window.location.protocol === "https:";

    if (isHttpUrl && isHttpsPage && this.proxyUrl) {
      log.debug("Using proxy URL for", streamType, "stream (HTTP -> HTTPS proxy required)");
      return this.toAbsoluteUrl(this.proxyUrl);
    }

    const proxyableTypes = ["ts", "xtream", "unknown"];
    if (this.useProxy && this.proxyUrl && proxyableTypes.includes(streamType)) {
      log.debug("Using proxy URL for", streamType, "stream");
      return this.toAbsoluteUrl(this.proxyUrl);
    }

    log.debug("Using direct URL for", streamType, "stream");
    return this.streamUrl;
  },

  shouldPreferAVPlayerForLiveTs() {
    return this.currentStreamType === "ts" && this.contentType === "live" && isFirefoxBrowser();
  },

  toAbsoluteUrl(url) {
    if (!url) return url;
    if (url.startsWith("http://") || url.startsWith("https://")) {
      return url;
    }
    return new URL(url, window.location.origin).href;
  },

  // ============================================
  // Player Initialization
  // ============================================

  cleanup() {
    if (this.streamLoader) {
      this.streamLoader.destroy();
      this.streamLoader = null;
    }
    this.hls = null;
    this.mpegtsPlayer = null;

    this.stopAVPlayerTimeUpdates();
    if (this.avPlayer) {
      this.avPlayer.destroy();
      this.avPlayer = null;
    }
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }
    if (this.nativePlaybackTimeout) {
      clearTimeout(this.nativePlaybackTimeout);
      this.nativePlaybackTimeout = null;
    }

    const avContainer = this.el?.querySelector("#avplayer-container");
    if (avContainer) {
      avContainer.remove();
    }

    this.usingAVPlayer = false;
    this.avPlayerAttempted = false;

    if (this.video) {
      this.video.src = "";
      this.video.load();
    }
  },

  initPlayer() {
    if (!this.streamUrl) {
      this.playerUI.showError("URL do stream nao fornecida");
      return;
    }

    this.playerUI.showLoading();
    log.info("Initializing player with URL:", this.streamUrl);
    log.debug("Streaming mode:", this.streamingMode);
    log.debug("Content type:", this.contentType);
    log.debug("Source type:", this.sourceType);

    // Log advanced feature availability
    if (isWebCodecsSupported()) {
      log.debug("WebCodecs API available - hardware acceleration possible");
    }
    if (isMSEInWorkersSupported()) {
      log.debug("MSE in Workers available - offloading parsing to worker thread");
    }
    if (this.codecABR) {
      log.debug("Codec-aware ABR active - optimizing quality selection by codec efficiency");
    }

    // Use explicit stream type hint from backend if available (token-based URLs have no extension)
    this.currentStreamType = this.el.dataset.streamType || getStreamType(this.streamUrl);
    log.debug("Detected stream type:", this.currentStreamType);

    this.cleanup();
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);

    // Create stream loader
    this.streamLoader = new StreamLoader({
      video: this.video,
      streamingMode: this.streamingMode,
      contentType: this.contentType,
      onManifestParsed: (data) => {
        log.info("Manifest parsed, levels:", data.levels.length);
        this.playerUI.hideLoading();
        this.playerUI.hideError();
        this.updateQualityList();
        this.updateAudioTracks();
        this.updateSubtitleTracks();

        // Resume from saved position if available
        if (this._savedPosition && this.contentType === "vod") {
          log.debug("Resuming from saved position:", this._savedPosition.time);
          this.seekTo(this._savedPosition.time);
          this._savedPosition = null; // Clear after use
        }

        this.video.play().catch((e) => {
          if (e.name === "AbortError") return; // play() interrupted by pause — harmless
          log.debug("Autoplay prevented:", e);
          this.playerUI.showPlayButton(() => this.video.play());
        });
      },
      onError: (type, data) => this.handleStreamError(type, data),
      onLevelSwitched: (level, levelData) => {
        const isAuto = this.manualQuality === null;
        this.pushEvent("quality_switched", {
          level,
          height: levelData?.height,
          bitrate: levelData?.bitrate,
          auto: isAuto,
        });

        // Show visual feedback for quality changes (only for auto switching)
        if (isAuto && levelData?.height) {
          const qualityLabel = `Auto: ${levelData.height}p`;
          this.playerUI.showQualityChange(qualityLabel);
        }
      },
      onAudioTracksUpdated: () => this.updateAudioTracks(),
      onSubtitleTracksUpdated: () => this.updateSubtitleTracks(),
      onFragLoaded: (bandwidth) => {
        this.networkMonitor?.addSample(bandwidth);
        // Feed bandwidth to codec-aware ABR
        if (this.codecABR) {
          this.codecABR.recordBandwidth(bandwidth / 1000); // Convert to kbps
        }
      },
      onMediaInfo: () => {
        this.playerUI.hideLoading();
        this.playerUI.hideError();
      },
      onStatisticsInfo: (bps) => this.networkMonitor?.addSample(bps),
    });

    // Send codec capabilities to backend for optimal stream selection
    const capabilities = getCapabilitySummary();
    this.pushEvent("player_initializing", {
      stream_type: this.currentStreamType,
      streaming_mode: this.streamingMode,
      pip_supported: this.isPiPSupported(),
      capabilities, // Send codec support info to backend
    });

    // Check Device Codec Memory for recommended player (Netflix pattern)
    const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
    const recommendedPlayer = getRecommendedPlayer(contentKey);

    if (recommendedPlayer === "avplayer" && !this.avPlayerAttempted) {
      log.debug("Using AVPlayer based on device compatibility history");
      this.tryAVPlayerFallback();
      return;
    }

    // Check for manual AVPlayer preference or GIndex sources
    if (this.preferAVPlayer && (this.sourceType === "gindex" || this.currentStreamType === "mkv")) {
      log.debug("Using AVPlayer due to user preference");
      this.tryAVPlayerFallback();
      return;
    }

    // GIndex uses native playback
    if (this.sourceType === "gindex") {
      log.debug("Using native playback for GIndex source");
      this.playNative();
      return;
    }

    switch (this.currentStreamType) {
      case "hls":
        this.playWithHls();
        break;
      case "ts":
      case "xtream":
        if (this.shouldPreferAVPlayerForLiveTs()) {
          log.debug("Using AVPlayer for live TS on Firefox");
          this.tryAVPlayerFallback();
          break;
        }

        if (isMpegtsSupported()) {
          this.playWithMpegts();
        } else if (isHlsJsSupported()) {
          this.playWithHls();
        } else {
          this.playNative();
        }
        break;
      case "flv":
        if (isMpegtsSupported()) {
          this.playWithMpegts("flv");
        } else {
          this.playerUI.showError("Reproducao FLV nao suportada neste navegador");
        }
        break;
      case "mp4":
      case "mkv":
        this.playNative();
        break;
      default:
        if (isHlsJsSupported()) {
          this.playWithHls();
        } else if (isMpegtsSupported()) {
          this.playWithMpegts();
        } else {
          this.playNative();
        }
    }
  },

  handleStreamError(type, data) {
    // Create enriched error report for telemetry
    const errorReport = createErrorReport(
      { message: data.details || data.errorDetail || "Stream error", type },
      {
        type,
        contentId: this.contentId,
        contentType: this.contentType,
        streamUrl: this.currentUrl,
        player: type,
        videoElement: this.video,
        playerState: {
          usingAVPlayer: this.usingAVPlayer,
          streamingMode: this.streamingMode,
          streamType: this.currentStreamType,
          sourceType: this.sourceType,
        },
        retryCount: this.retryCount,
        fallbackAttempt: this.fallbackAttempts,
        fatal: data.fatal,
      },
    );

    log.debug(formatErrorForLog(errorReport));

    // Send enriched error to backend
    this.pushEvent("player_error", {
      ...errorReport,
      patterns: detectErrorPatterns(),
    });

    if (type === "hls") {
      // Track recovery attempts
      this._hlsRecoveryAttempts = this._hlsRecoveryAttempts || 0;

      // Non-fatal errors - just log
      if (!data.fatal) {
        log.debug("HLS non-fatal error:", data.details);
        return;
      }

      // Check for auth errors (403/401)
      if (data.response?.code === 403 || data.response?.code === 401) {
        log.warn("Auth error detected, requesting token refresh");
        this.pushEvent("request_token_refresh", {});
        return;
      }

      switch (data.type) {
        case "networkError":
          if (
            data.details === "manifestLoadError" ||
            data.details === "manifestParsingError"
          ) {
            // First try soft reload
            if (this._hlsRecoveryAttempts < 2 && this.streamLoader?.canSoftReload("hls")) {
              this._hlsRecoveryAttempts++;
              log.warn(`Soft recovering HLS (attempt ${this._hlsRecoveryAttempts})...`);
              setTimeout(() => {
                this.streamLoader?.loadHlsSoft(this.currentUrl);
              }, 1000 * this._hlsRecoveryAttempts); // Increasing delay
              return;
            }
            // Then try different player
            if (this.retryCount < this.maxRetries && isMpegtsSupported()) {
              this.retryCount++;
              log.warn("HLS failed, trying mpegts.js...");
              this.cleanup();
              this.playWithMpegts();
            } else {
              this.showErrorWithDiagnostics(
                "Nao foi possivel carregar - servidor indisponivel",
                { message: "Manifest load failed", type: "network" },
                true,
              );
            }
          } else {
            // Fragment/level load errors - try soft recovery first
            if (this._hlsRecoveryAttempts < 3) {
              this._hlsRecoveryAttempts++;
              log.warn(`Network error, soft recovering (attempt ${this._hlsRecoveryAttempts})...`);
              this.streamLoader?.startLoad();
            } else {
              log.warn("Network recovery failed, reloading stream...");
              this._hlsRecoveryAttempts = 0;
              this.streamLoader?.loadHlsSoft(this.currentUrl);
            }
          }
          break;
        case "mediaError":
          if (this._hlsRecoveryAttempts < 2) {
            this._hlsRecoveryAttempts++;
            log.warn(`Media error, recovering (attempt ${this._hlsRecoveryAttempts})...`);
            this.streamLoader?.recoverMediaError();
          } else {
            log.warn("Media recovery failed, reloading stream...");
            this._hlsRecoveryAttempts = 0;
            this.streamLoader?.loadHlsSoft(this.currentUrl);
          }
          break;
        default:
          if (this.retryCount < this.maxRetries) {
            this.retryCount++;
            this.cleanup();
            if (isMpegtsSupported()) {
              this.playWithMpegts();
            } else {
              this.playNative();
            }
          } else {
            this.showErrorWithDiagnostics(
              "Erro de reproducao - formato nao suportado",
              { message: "Media format error", type: "codec" },
              true,
            );
          }
      }
    } else if (type === "mpegts") {
      const { errorType, errorDetail } = data;

      if (this.shouldPreferAVPlayerForLiveTs() && !this.usingAVPlayer && !this.avPlayerAttempted) {
        log.warn("mpegts.js failed for live TS on Firefox, trying AVPlayer...");
        this.cleanup();
        this.tryAVPlayerFallback();
        return;
      }

      if (this.useProxy && this.currentUrl !== this.streamUrl) {
        log.warn("Proxy failed, trying direct URL...");
        this.useProxy = false;
        this.currentUrl = this.streamUrl;
        this.cleanup();
        this.playWithMpegts();
        return;
      }

      if (this.retryCount < this.maxRetries) {
        this.retryCount++;
        log.warn(`Retrying with different method (${this.retryCount}/${this.maxRetries})`);
        this.cleanup();

        if (isHlsJsSupported()) {
          this.playWithHls();
        } else {
          this.playNative();
        }
      } else {
        this.playerUI.showError(`Erro no stream: ${errorDetail || errorType}`);
      }
    }
  },

  async playWithHls() {
    log.info("Playing with HLS.js, url:", this.currentUrl);

    if (!isHlsJsSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.playerUI.showError("HLS nao suportado neste navegador");
      }
      return;
    }

    this.hls = await this.streamLoader.loadHls(this.currentUrl);
  },

  async playWithMpegts(type = "mpegts") {
    if (type === "mpegts" && this.shouldPreferAVPlayerForLiveTs()) {
      log.debug("Skipping mpegts.js for live TS on Firefox, forcing AVPlayer");
      this.tryAVPlayerFallback();
      return;
    }

    log.info("Playing with mpegts.js, type:", type, "url:", this.currentUrl);

    try {
      this.mpegtsPlayer = await this.streamLoader.loadMpegts(this.currentUrl, type);

      this.video.play().catch((e) => {
        if (e.name === "AbortError") return; // play() interrupted by pause — harmless
        log.debug("Autoplay prevented:", e);
        if (e.name === "NotAllowedError") {
          this.playerUI.hideLoading();
          this.playerUI.showPlayButton(() => this.video.play());
        }
      });

      this.video.addEventListener(
        "playing",
        () => {
          this.playerUI.hideLoading();
          this.playerUI.hideError();
        },
        { once: true },
      );
    } catch (e) {
      console.error("mpegts.js initialization error:", e);
      if (isHlsJsSupported()) {
        this.playWithHls();
      } else {
        this.playNative();
      }
    }
  },

  playNative() {
    log.info("Playing with native video element, url:", this.currentUrl);
    this.video.src = this.currentUrl;

    const playHandler = () => {
      log.debug("Native playback started");
      this.playerUI.hideLoading();
      this.playerUI.hideError();
      this.video.removeEventListener("playing", playHandler);

      if (this.nativePlaybackTimeout) {
        clearTimeout(this.nativePlaybackTimeout);
        this.nativePlaybackTimeout = null;
      }

      // Initialize Native Buffer Manager for MP4/MKV streams
      if (!this.nativeBufferManager && this.contentType === "vod") {
        this.nativeBufferManager = new NativeBufferManager(this.video, {
          onBufferHealthChange: (status) => {
            log.debug(`[NativeBuffer] Health: ${status.health}, buffer: ${status.bufferAhead.toFixed(1)}s`);
          },
          onStall: (info) => {
            log.warn(`[NativeBuffer] Stall detected #${info.totalStalls}`);
            this.playerUI.showLoading();
          },
          onRecovery: () => {
            this.playerUI.hideLoading();
          },
        });
        this.nativeBufferManager.start();
        log.info("[VideoPlayer] Native buffer monitoring enabled");
      }

      // Resume from saved position if available (VOD only)
      if (this._savedPosition && this.contentType === "vod") {
        log.debug("Resuming from saved position:", this._savedPosition.time);
        this.seekTo(this._savedPosition.time);
        this._savedPosition = null;
      }

      // Check for audio issues (MP4/MKV files may have AC3/DTS audio not supported by browsers)
      // Run audio detection for all VOD content, including GIndex (which often has unknown stream type)
      const needsAudioCheck =
        this.contentType === "vod" &&
        (this.currentStreamType === "mp4" ||
          this.currentStreamType === "mkv" ||
          this.sourceType === "gindex" || // GIndex URLs don't have extensions
          this.currentStreamType === "unknown"); // Unknown types might have unsupported audio
      if (needsAudioCheck) {
        this.checkAudioAndFallback();
      }

      // For GIndex content, probe metadata in background to detect audio/subtitle tracks
      // This allows native player to start fast while we detect available tracks
      if (this.sourceType === "gindex") {
        this.probeMetadataInBackground();
      }

      // Record successful native playback after 5s (confirms no fallback needed)
      // This helps Device Codec Memory learn that native works for this content type
      if (!needsAudioCheck) {
        setTimeout(() => {
          if (!this.usingAVPlayer && !this.video.paused) {
            const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
            recordPlayerSuccess(contentKey, "native", {
              sourceType: this.sourceType,
              streamType: this.currentStreamType,
            });
          }
        }, 5000);
      }
    };

    const errorHandler = () => {
      if (this.usingAVPlayer || this.avPlayerAttempted) {
        log.debug("[VideoPlayer] Ignoring native video error - AVPlayer is active");
        return;
      }

      const error = this.video.error;
      let message = "Falha na reproducao";

      if (error) {
        switch (error.code) {
          case MediaError.MEDIA_ERR_ABORTED:
            message = "Reproducao cancelada";
            break;
          case MediaError.MEDIA_ERR_NETWORK:
            message = "Erro de rede - verifique sua conexao";
            break;
          case MediaError.MEDIA_ERR_DECODE:
          case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED: {
            // Try AVPlayer for any VOD content that may have unsupported codecs
            const canTryAVPlayer =
              this.contentType === "vod" &&
              !this.avPlayerAttempted &&
              (this.currentStreamType === "mp4" ||
                this.currentStreamType === "mkv" ||
                this.sourceType === "gindex" ||
                this.currentStreamType === "unknown");
            if (canTryAVPlayer) {
              log.debug("[VideoPlayer] Format not supported, trying AVPlayer fallback");
              this.tryAVPlayerFallback();
              return;
            }
            message = "Formato nao suportado pelo navegador";
            break;
          }
        }
      }

      this.playerUI.showError(message);
      this.video.removeEventListener("error", errorHandler);
    };

    this._nativeErrorHandler = errorHandler;

    this.video.addEventListener("playing", playHandler);
    this.video.addEventListener("error", errorHandler);
    this.video.addEventListener("loadedmetadata", () => this.playerUI.hideLoading(), {
      once: true,
    });

    this.video.play().catch((e) => {
      if (e.name === "AbortError") return; // play() interrupted by pause — harmless
      log.debug("Native autoplay prevented:", e);
      this.playerUI.hideLoading();
      if (e.name === "NotAllowedError") {
        this.playerUI.showPlayButton(() => this.video.play());
      } else if (e.name === "NotSupportedError") {
        // Check if AVPlayer fallback is available before showing error
        const canTryAVPlayer =
          this.contentType === "vod" &&
          !this.avPlayerAttempted &&
          (this.currentStreamType === "mp4" ||
            this.currentStreamType === "mkv" ||
            this.sourceType === "gindex" ||
            this.currentStreamType === "unknown");

        if (canTryAVPlayer) {
          log.debug("[VideoPlayer] Native play failed, AVPlayer fallback will be attempted");
          // Don't show error - errorHandler will try AVPlayer
        } else {
          this.playerUI.showError(`Falha ao iniciar reproducao: ${e.message}`);
        }
      } else {
        this.playerUI.showError(`Falha ao iniciar reproducao: ${e.message}`);
      }
    });
  },

  // ============================================
  // Audio Detection and AVPlayer Fallback
  // ============================================

  async checkAudioAndFallback() {
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
    }

    this.audioCheckTimeout = setTimeout(async () => {
      try {
        const { detectAudioIssue } = await loadAVPlayer();
        const hasAudioIssue = await detectAudioIssue(this.video);

        if (hasAudioIssue) {
          log.debug("[VideoPlayer] Audio issue detected, auto-switching to AVPlayer");
          this.tryAVPlayerFallback();
        } else {
          log.debug("[VideoPlayer] Audio working correctly");
        }
      } catch (e) {
        console.warn("[VideoPlayer] Could not check audio:", e);
        this.audioCheckTimeout = null;
      }
    }, 2000);
  },

  /**
   * Check circuit breaker before attempting fallback (exponential backoff)
   */
  canAttemptFallback() {
    const now = Date.now();

    // Check if we've exceeded max attempts
    if (this.fallbackAttempts >= this.maxFallbackAttempts) {
      // Use last cooldown value (max) for reset check
      const maxCooldown = this.fallbackCooldowns[this.fallbackCooldowns.length - 1];
      if (now - this.lastFallbackTime < maxCooldown) {
        log.debug("[VideoPlayer] Circuit breaker: max attempts reached, cooling down");
        return false;
      }
      // Reset after cooldown
      this.fallbackAttempts = 0;
    }

    // Check exponential backoff between attempts
    if (this.fallbackAttempts > 0 && this.lastFallbackTime > 0) {
      const cooldownIndex = Math.min(this.fallbackAttempts - 1, this.fallbackCooldowns.length - 1);
      const requiredCooldown = this.fallbackCooldowns[cooldownIndex];
      const elapsed = now - this.lastFallbackTime;

      if (elapsed < requiredCooldown) {
        const remaining = Math.ceil((requiredCooldown - elapsed) / 1000);
        log.debug(
          `[VideoPlayer] Circuit breaker: waiting ${remaining}s (attempt ${this.fallbackAttempts})`,
        );
        return false;
      }
    }

    return true;
  },

  async tryAVPlayerFallback() {
    // Prevent duplicate switch attempts
    if (this._switchingToAVPlayer) {
      log.debug("[VideoPlayer] Already switching to AVPlayer, skipping fallback");
      return;
    }

    // Circuit breaker check
    if (!this.canAttemptFallback()) {
      log.debug("[VideoPlayer] Circuit breaker prevented fallback attempt");
      this.playerUI.showError("Formato de audio nao suportado. Tente novamente mais tarde.");
      return;
    }

    if (this.avPlayerAttempted || this.usingAVPlayer) {
      log.debug("[VideoPlayer] AVPlayer fallback already attempted, skipping");
      return;
    }

    this._switchingToAVPlayer = true;

    this.avPlayerAttempted = true;
    this.fallbackAttempts++;
    this.lastFallbackTime = Date.now();

    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }

    log.debug("[VideoPlayer] Attempting AVPlayer fallback (seamless)");
    this.playerUI.hideError();

    const currentTime = this.video.currentTime || 0;
    const wasPlaying = !this.video.paused;

    this.video.pause();

    if (this._nativeErrorHandler) {
      this.video.removeEventListener("error", this._nativeErrorHandler);
    }

    try {
      // Lazy load AVPlayer
      const { AVPlayerWrapper } = await loadAVPlayer();

      const avContainer = document.createElement("div");
      avContainer.id = "avplayer-container";
      avContainer.className = "absolute inset-0 z-0";
      this.el.appendChild(avContainer);

      this.video.classList.add("hidden");
      this.video.src = "";

      this.avPlayer = new AVPlayerWrapper({
        container: avContainer,
        onReady: () => log.debug("[VideoPlayer] AVPlayer ready"),
        onPlay: () => {
          log.debug("[VideoPlayer] AVPlayer playing with audio support");
          this.playerUI.hideLoading();
          this.playerUI.updatePlayPauseUI(false);
          this.startAVPlayerTimeUpdates();

          // Record successful AVPlayer playback for Device Codec Memory
          const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
          recordPlayerSuccess(contentKey, "avplayer", {
            sourceType: this.sourceType,
            streamType: this.currentStreamType,
          });
        },
        onPause: () => {
          log.debug("[VideoPlayer] AVPlayer paused");
          this.playerUI.updatePlayPauseUI(true);
        },
        onError: (error) => {
          log.error("[VideoPlayer] AVPlayer error:", error);
          this.revertToNativePlayer();
        },
        onTimeUpdate: () => this.updateTimeUI(),
        onEnded: () => {
          log.debug("[VideoPlayer] AVPlayer ended");
          this.playerUI.updatePlayPauseUI(true);
          this.stopAVPlayerTimeUpdates();
        },
      });

      const avPlayerUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;

      const ext = getFileExtension(this.streamUrl, this.sourceType, this.currentStreamType);
      log.debug("[VideoPlayer] AVPlayer loading via:", avPlayerUrl, "ext:", ext);

      await this.avPlayer.load(avPlayerUrl, { ext });

      if (currentTime > 0) {
        await this.avPlayer.seek(currentTime);
      }

      // Apply saved volume (convert UI value to perceived)
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : linearToPerceived(this.avPlayerVolume));

      log.debug("[VideoPlayer] Calling AVPlayer play(), wasPlaying:", wasPlaying);
      await this.avPlayer.play();
      log.debug("[VideoPlayer] AVPlayer play() completed");

      this.usingAVPlayer = true;
      log.debug("[VideoPlayer] Seamless AVPlayer switch complete");

      // Detect available audio/subtitle tracks from AVPlayer
      this.detectAVPlayerTracks();
    } catch (error) {
      log.error("[VideoPlayer] AVPlayer fallback failed:", error);
      this.revertToNativePlayer();
    } finally {
      this._switchingToAVPlayer = false;
    }
  },

  /**
   * Detect and expose audio/subtitle tracks from AVPlayer
   */
  async detectAVPlayerTracks() {
    if (!this.avPlayer) return;

    try {
      // Small delay to let AVPlayer fully initialize streams
      await new Promise((resolve) => setTimeout(resolve, 500));

      // Get audio tracks
      const audioTracks = await this.avPlayer.getAudioTracks();
      if (audioTracks && audioTracks.length > 0) {
        this.audioTracks = audioTracks.map((track, index) => ({
          index,
          id: track.id,
          label: this.formatTrackLabel(track),
          language: track.language || "",
          codec: track.codec || "",
        }));

        const currentTrack = audioTracks.findIndex((t) => t.selected) || 0;

        this.playerUI.updateAudioOptions(this.audioTracks, currentTrack, (track) =>
          this.setAVPlayerAudioTrack(track),
        );

        // Apply saved preference
        if (
          this._preferredAudioTrack !== null &&
          this._preferredAudioTrack < this.audioTracks.length
        ) {
          this.setAVPlayerAudioTrack(this._preferredAudioTrack);
        }

        this.pushEvent("audio_tracks_available", {
          tracks: this.audioTracks,
          current: currentTrack,
        });

        log.debug("[VideoPlayer] AVPlayer audio tracks detected:", this.audioTracks);
      }

      // Get subtitle tracks
      const subtitleTracks = await this.avPlayer.getSubtitleTracks();
      if (subtitleTracks && subtitleTracks.length > 0) {
        this.subtitleTracks = subtitleTracks.map((track, index) => ({
          index,
          id: track.id,
          label: this.formatTrackLabel(track),
          language: track.language || "",
        }));

        const currentTrack = subtitleTracks.findIndex((t) => t.selected);

        this.playerUI.updateSubtitleOptions(this.subtitleTracks, currentTrack, (track) =>
          this.setAVPlayerSubtitleTrack(track),
        );

        // Apply saved preference
        if (
          this._preferredSubtitleTrack !== null &&
          this._preferredSubtitleTrack < this.subtitleTracks.length
        ) {
          this.setAVPlayerSubtitleTrack(this._preferredSubtitleTrack);
        }

        this.pushEvent("subtitle_tracks_available", {
          tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
          current: currentTrack,
        });

        log.debug("[VideoPlayer] AVPlayer subtitle tracks detected:", this.subtitleTracks);
      }
    } catch (e) {
      log.warn("[VideoPlayer] Failed to detect AVPlayer tracks:", e);
    }
  },

  /**
   * Format track label from track metadata
   */
  formatTrackLabel(track) {
    const parts = [];
    if (
      track.label &&
      track.label !== `Audio ${track.index + 1}` &&
      track.label !== `Subtitle ${track.index + 1}`
    ) {
      parts.push(track.label);
    }
    if (track.language) {
      const langName = this.getLanguageName(track.language);
      if (!parts.includes(langName)) {
        parts.push(langName);
      }
    }
    if (track.codec) {
      parts.push(`(${track.codec})`);
    }
    if (track.channels && track.channels > 0) {
      parts.push(`${track.channels}ch`);
    }
    return parts.length > 0 ? parts.join(" ") : `Track ${track.index + 1}`;
  },

  /**
   * Get human readable language name
   */
  getLanguageName(code) {
    const languages = {
      por: "Português",
      pt: "Português",
      "pt-BR": "Português (BR)",
      eng: "English",
      en: "English",
      spa: "Español",
      es: "Español",
      jpn: "Japanese",
      ja: "Japanese",
      und: "Indefinido",
    };
    return languages[code] || code;
  },

  /**
   * Set audio track for AVPlayer
   */
  async setAVPlayerAudioTrack(trackIndex) {
    if (!this.avPlayer || !this.audioTracks[trackIndex]) return;

    try {
      const track = this.audioTracks[trackIndex];
      await this.avPlayer.selectAudioTrack(track.id);
      this.selectedAudioTrack = trackIndex;
      saveAudioTrack(trackIndex, this.contentId);

      this.pushEvent("audio_track_changed", {
        track: trackIndex,
        label: track.label,
      });
      log.debug("[VideoPlayer] AVPlayer audio track changed to:", track.label);
    } catch (e) {
      log.error("[VideoPlayer] Failed to change AVPlayer audio track:", e);
    }
  },

  /**
   * Set subtitle track for AVPlayer (-1 to disable)
   */
  async setAVPlayerSubtitleTrack(trackIndex) {
    if (!this.avPlayer) return;

    try {
      if (trackIndex === -1) {
        await this.avPlayer.selectSubtitleTrack(-1);
        this.selectedSubtitleTrack = -1;
        saveSubtitleTrack(-1, this.contentId);
        this.pushEvent("subtitle_track_changed", { track: -1, label: "Desativado" });
      } else if (this.subtitleTracks[trackIndex]) {
        const track = this.subtitleTracks[trackIndex];
        await this.avPlayer.selectSubtitleTrack(track.id);
        this.selectedSubtitleTrack = trackIndex;
        saveSubtitleTrack(trackIndex, this.contentId);
        this.pushEvent("subtitle_track_changed", {
          track: trackIndex,
          label: track.label,
        });
        log.debug("[VideoPlayer] AVPlayer subtitle track changed to:", track.label);
      }
    } catch (e) {
      log.error("[VideoPlayer] Failed to change AVPlayer subtitle track:", e);
    }
  },

  /**
   * Probe metadata in background using AVPlayer
   * This detects audio/subtitle tracks without switching the active player
   * Netflix-style progressive enhancement: fast start with native, enhance UI when tracks detected
   */
  async probeMetadataInBackground() {
    // Skip if we're already using AVPlayer or already probed
    if (this.usingAVPlayer || this._metadataProbed) return;
    this._metadataProbed = true;

    log.debug("[VideoPlayer] Starting background metadata probe...");

    try {
      // Get AVPlayer wrapper module
      const { AVPlayerWrapper } = await import("../lib/avplayer_wrapper.js");

      // Create a probe-only AVPlayer (won't actually play)
      const probeContainer = document.createElement("div");
      probeContainer.style.cssText =
        "position:absolute;width:1px;height:1px;opacity:0;pointer-events:none;overflow:hidden;";
      this.el.appendChild(probeContainer);

      const probePlayer = new AVPlayerWrapper({
        container: probeContainer,
        onReady: () => {},
        onError: (error) => {
          log.warn("[VideoPlayer] Probe failed:", error);
        },
      });

      // Initialize the probe player
      await probePlayer.init();

      // Get the proxy URL for GIndex (use proxyUrl if available, otherwise direct URL)
      const probeUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;
      // For GIndex content, default to mkv since URL parsing is unreliable
      const ext =
        this.sourceType === "gindex"
          ? "mkv"
          : this.streamUrl.split(".").pop()?.split("?")[0] || "mkv";

      log.debug("[VideoPlayer] Probe loading:", probeUrl);
      await probePlayer.load(probeUrl, { ext });

      // Give it a moment to parse the container
      await new Promise((resolve) => setTimeout(resolve, 1000));

      // Get audio tracks
      const audioTracks = await probePlayer.getAudioTracks();
      let preferredAudioTrack = 0;

      if (audioTracks && audioTracks.length > 1) {
        this._probedAudioTracks = audioTracks.map((track, index) => ({
          index,
          id: track.id,
          label: this.formatTrackLabel(track),
          language: track.language || "",
        }));

        log.debug("[VideoPlayer] Probed audio tracks:", this._probedAudioTracks);

        // Find Portuguese audio track (prefer pt-BR over others)
        preferredAudioTrack = this.findPortugueseTrack(this._probedAudioTracks);

        // Update UI with detected tracks
        // Use special handlers that will switch to AVPlayer when selected
        this.playerUI.updateAudioOptions(
          this._probedAudioTracks,
          preferredAudioTrack,
          (trackIndex) => this.handleProbedAudioTrackSelect(trackIndex),
        );

        this.pushEvent("audio_tracks_available", {
          tracks: this._probedAudioTracks,
          current: preferredAudioTrack,
        });
      }

      // Get subtitle tracks
      const subtitleTracks = await probePlayer.getSubtitleTracks();
      if (subtitleTracks && subtitleTracks.length > 0) {
        this._probedSubtitleTracks = subtitleTracks.map((track, index) => ({
          index,
          id: track.id,
          label: this.formatTrackLabel(track),
          language: track.language || "",
        }));

        log.debug("[VideoPlayer] Probed subtitle tracks:", this._probedSubtitleTracks);

        // Update UI with detected tracks
        this.playerUI.updateSubtitleOptions(this._probedSubtitleTracks, -1, (trackIndex) =>
          this.handleProbedSubtitleTrackSelect(trackIndex),
        );

        this.pushEvent("subtitle_tracks_available", {
          tracks: [{ index: -1, label: "Desativado" }, ...this._probedSubtitleTracks],
          current: -1,
        });
      }

      // Clean up probe player
      probePlayer.destroy();
      probeContainer.remove();

      log.debug("[VideoPlayer] Background metadata probe complete");

      // Auto-switch to AVPlayer when multiple audio tracks detected (Dual Audio)
      // Native player can't guarantee which track plays, so we switch to control audio selection
      if (this._probedAudioTracks && this._probedAudioTracks.length > 1) {
        log.debug(
          "[VideoPlayer] Multiple audio tracks detected, auto-switching to AVPlayer with Portuguese track",
          preferredAudioTrack,
        );
        // Short delay to let native player stabilize before switch
        await new Promise((resolve) => setTimeout(resolve, 500));
        this.handleProbedAudioTrackSelect(preferredAudioTrack);
      }
    } catch (e) {
      log.warn("[VideoPlayer] Failed to start metadata probe:", e);
    }
  },

  /**
   * Find Portuguese audio track (prefers pt-BR)
   * Returns the track index or 0 if not found
   */
  findPortugueseTrack(tracks) {
    if (!tracks || tracks.length <= 1) return 0;

    // Priority order for Portuguese variants
    const ptPatterns = [
      /\bpt[-_]?br\b/i, // pt-br, pt_br, ptbr
      /\bportugu[eê]s?\b/i, // portuguese
      /\bbrazil/i, // brazilian
      /\bpt\b/i, // pt (generic portuguese)
      /\bpor\b/i, // por (ISO 639-2)
    ];

    for (const pattern of ptPatterns) {
      const found = tracks.find((t) => pattern.test(t.language) || pattern.test(t.label));
      if (found) {
        log.debug("[VideoPlayer] Found Portuguese track:", found.label, "at index", found.index);
        return found.index;
      }
    }

    return 0; // Default to first track
  },

  /**
   * Handle audio track selection from probed tracks (switches to AVPlayer)
   */
  async handleProbedAudioTrackSelect(trackIndex) {
    // Prevent duplicate switch attempts
    if (this._switchingToAVPlayer) {
      log.debug("[VideoPlayer] Already switching to AVPlayer, ignoring...");
      return;
    }

    // If already using AVPlayer, just change the track
    if (this.usingAVPlayer && this.avPlayer) {
      this.audioTracks = this._probedAudioTracks;
      await this.setAVPlayerAudioTrack(trackIndex);
      return;
    }

    log.debug("[VideoPlayer] User selected audio track, switching to AVPlayer...");

    // Save current position before switching
    const currentTime = this.video.currentTime;
    const wasPlaying = !this.video.paused;

    // Switch to AVPlayer with selected track
    await this.switchToAVPlayerWithTrack("audio", trackIndex, currentTime, wasPlaying);
  },

  /**
   * Handle subtitle track selection from probed tracks (switches to AVPlayer)
   */
  async handleProbedSubtitleTrackSelect(trackIndex) {
    // Prevent duplicate switch attempts
    if (this._switchingToAVPlayer) {
      log.debug("[VideoPlayer] Already switching to AVPlayer, ignoring...");
      return;
    }

    // If already using AVPlayer, just change the track
    if (this.usingAVPlayer && this.avPlayer) {
      this.subtitleTracks = this._probedSubtitleTracks || [];
      await this.setAVPlayerSubtitleTrack(trackIndex);
      return;
    }

    if (trackIndex === -1) {
      // Subtitles disabled, no need to switch if not using AVPlayer
      log.debug("[VideoPlayer] Subtitles disabled, staying on native");
      return;
    }

    log.debug("[VideoPlayer] User selected subtitle track, switching to AVPlayer...");

    // Save current position before switching
    const currentTime = this.video.currentTime;
    const wasPlaying = !this.video.paused;

    // Switch to AVPlayer
    await this.switchToAVPlayerWithTrack("subtitle", trackIndex, currentTime, wasPlaying);
  },

  /**
   * Switch from native to AVPlayer and apply selected track
   */
  async switchToAVPlayerWithTrack(trackType, trackIndex, seekTime, shouldPlay) {
    // Prevent duplicate switch attempts
    if (this._switchingToAVPlayer) {
      log.debug("[VideoPlayer] Already switching to AVPlayer, ignoring duplicate call");
      return;
    }
    this._switchingToAVPlayer = true;

    this.playerUI.showLoading();

    try {
      // Stop native player
      this.video.pause();
      this.video.src = "";

      // Initialize AVPlayer if not already
      if (!this.avPlayer) {
        const { AVPlayerWrapper } = await import("../lib/avplayer_wrapper.js");

        // Create container if it doesn't exist
        let avContainer = this.el.querySelector("#avplayer-container");
        if (!avContainer) {
          avContainer = document.createElement("div");
          avContainer.id = "avplayer-container";
          avContainer.className = "absolute inset-0 z-0";
          this.el.appendChild(avContainer);
        }

        this.avPlayer = new AVPlayerWrapper({
          container: avContainer,
          onReady: () => log.debug("[VideoPlayer] AVPlayer ready for track switch"),
          onError: (e) => log.error("[VideoPlayer] AVPlayer error:", e),
          onPlay: () => {
            this.playerUI.updatePlayPauseUI(false); // false = not paused
            this.playerUI.hideLoading();
            this.startAVPlayerTimeUpdates();
          },
          onPause: () => this.playerUI.updatePlayPauseUI(true), // true = paused
          onTimeUpdate: () => this.updateTimeUI(),
          onEnded: () => {
            this.playerUI.updatePlayPauseUI(true);
            this.stopAVPlayerTimeUpdates();
          },
        });

        await this.avPlayer.init();
      }

      // Load the stream (use proxyUrl if available, otherwise direct URL)
      const proxyUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;
      // For GIndex content, default to mkv since URL parsing is unreliable
      const ext =
        this.sourceType === "gindex"
          ? "mkv"
          : this.streamUrl.split(".").pop()?.split("?")[0] || "mkv";
      await this.avPlayer.load(proxyUrl, { ext });

      // Apply volume settings
      this.avPlayer.setVolume(this.avPlayerVolume);
      if (this.avPlayerMuted) {
        this.avPlayer.mute();
      }

      // Mark as using AVPlayer
      this.usingAVPlayer = true;
      this.video.classList.add("hidden");
      const avContainer = this.el.querySelector("#avplayer-container");
      if (avContainer) avContainer.classList.remove("hidden");

      // Seek to saved position
      if (seekTime > 0) {
        await this.avPlayer.seek(seekTime);
      }

      // Apply the selected track
      if (trackType === "audio" && this._probedAudioTracks?.[trackIndex]) {
        this.audioTracks = this._probedAudioTracks;
        await this.setAVPlayerAudioTrack(trackIndex);
      } else if (trackType === "subtitle") {
        this.subtitleTracks = this._probedSubtitleTracks || [];
        await this.setAVPlayerSubtitleTrack(trackIndex);
      }

      // Start playback
      if (shouldPlay) {
        await this.avPlayer.play();
      }

      // Start time updates
      this.startAVPlayerTimeUpdates();

      // Detect tracks from now-active AVPlayer
      this.detectAVPlayerTracks();

      this.playerUI.hideLoading();
      log.debug("[VideoPlayer] Switched to AVPlayer with", trackType, "track", trackIndex);
    } catch (error) {
      log.error("[VideoPlayer] Failed to switch to AVPlayer:", error);
      this.playerUI.hideLoading();
      this.playerUI.showError("Falha ao carregar faixas de áudio/legenda");
    } finally {
      this._switchingToAVPlayer = false;
    }
  },

  revertToNativePlayer() {
    log.debug("[VideoPlayer] Reverting to native player");

    this.stopAVPlayerTimeUpdates();

    if (this.avPlayer) {
      this.avPlayer.destroy();
      this.avPlayer = null;
    }

    const avContainer = this.el.querySelector("#avplayer-container");
    if (avContainer) {
      avContainer.remove();
    }

    this.video.classList.remove("hidden");
    this.usingAVPlayer = false;
  },

  toggleAVPlayerPreference() {
    this.preferAVPlayer = !this.preferAVPlayer;
    savePreferAVPlayer(this.preferAVPlayer);

    log.debug("[VideoPlayer] AVPlayer preference toggled:", this.preferAVPlayer);

    // Restart player with new preference
    if (this.sourceType === "gindex" || this.currentStreamType === "mkv") {
      this.avPlayerAttempted = false;
      this.fallbackAttempts = 0;
      this.initPlayer();
    }

    this.pushEvent("avplayer_preference_changed", { enabled: this.preferAVPlayer });
  },

  startAVPlayerTimeUpdates() {
    this.stopAVPlayerTimeUpdates();
    this._avPlayerAnimating = true;
    this._lastProgressUpdate = 0;

    const updateLoop = (timestamp) => {
      if (!this._avPlayerAnimating) return;

      if (this.usingAVPlayer && this.avPlayer) {
        // Update time UI on every frame for smooth progress bar
        this.updateTimeUI();

        // Throttle progress reporting to server (every 10s as per reportProgress)
        // Only throttle the heavy operation, not the UI update
        if (this.contentType === "vod" && timestamp - this._lastProgressUpdate >= 10000) {
          this._lastProgressUpdate = timestamp;
          this.reportProgress();
        }
      }

      this.avPlayerTimeInterval = requestAnimationFrame(updateLoop);
    };

    this.avPlayerTimeInterval = requestAnimationFrame(updateLoop);
  },

  stopAVPlayerTimeUpdates() {
    this._avPlayerAnimating = false;
    if (this.avPlayerTimeInterval) {
      cancelAnimationFrame(this.avPlayerTimeInterval);
      this.avPlayerTimeInterval = null;
    }
  },

  // ============================================
  // Mobile Touch Controls
  // ============================================

  setupMobileControls() {
    const controls = this.el.querySelector("#player-controls");
    if (!controls) return;

    this.lastTapTime = 0;
    const isTouchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;

    if (isTouchDevice) {
      this.video.addEventListener("click", (e) => {
        e.preventDefault();
        const now = Date.now();
        const timeSinceLastTap = now - this.lastTapTime;

        if (timeSinceLastTap < 300) {
          this.toggleFullscreen();
        } else {
          this.playerUI.toggleControlsVisibility();
        }

        this.lastTapTime = now;
      });

      this.playerUI.showControls();
      this.playerUI.scheduleHideControls();

      controls.addEventListener("touchstart", () => {
        this.playerUI.clearHideControlsTimeout();
      });

      controls.addEventListener("touchend", () => {
        this.playerUI.scheduleHideControls();
      });
    }

    this.el.addEventListener("mousemove", () => {
      if (!isTouchDevice) {
        this.playerUI.showControls();
        this.playerUI.scheduleHideControls();
      }
    });

    this.video.addEventListener("play", () => {
      this.playerUI.scheduleHideControls();
    });

    this.video.addEventListener("pause", () => {
      this.playerUI.showControls();
      this.playerUI.clearHideControlsTimeout();
    });
  },

  // ============================================
  // Keyboard Shortcuts (YouTube-style)
  // ============================================

  setupKeyboardShortcuts() {
    this.keyboardManager = new KeyboardManager({
      contentType: this.contentType,
      showFeedback: (icon) => this.playerUI.showShortcutFeedback(icon),
      actions: {
        togglePlayPause: () => this.togglePlayPause(),
        toggleMute: () => this.toggleMute(),
        toggleFullscreen: () => this.toggleFullscreen(),
        togglePiP: () => this.togglePiP(),
        adjustVolume: (delta) => this.adjustVolume(delta),
        seek: (seconds) => this.seek(seconds),
        seekTo: (time) => this.seekTo(time),
        setPlaybackRate: (rate) => this.setPlaybackRate(rate),
        getDuration: () => this.getDuration(),
        isPaused: () => this.isPaused(),
        isMuted: () => (this.usingAVPlayer ? this.avPlayerMuted : this.video?.muted),
        isPiPSupported: () => this.isPiPSupported(),
        getPlaybackRate: () => this.video?.playbackRate || 1,
      },
    });

    this.keyboardManager.start();
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      this.el.requestFullscreen?.() || this.video.requestFullscreen?.();
    }
  },

  async togglePlayPause() {
    if (this.usingAVPlayer && this.avPlayer) {
      const isPlaying = this.avPlayer.isPlaying();
      log.debug("[VideoPlayer] togglePlayPause: AVPlayer isPlaying =", isPlaying);
      if (isPlaying) {
        await this.avPlayer.pause();
      } else {
        try {
          await this.avPlayer.play();
        } catch (err) {
          log.error("[VideoPlayer] AVPlayer play() failed:", err);
        }
      }
    } else {
      if (this.video.paused) {
        this.video.play().catch((e) => {
          if (e.name === "AbortError") return;
          log.debug("[VideoPlayer] togglePlayPause play() failed:", e.message);
        });
      } else {
        this.video.pause();
      }
    }
  },

  toggleMute() {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayerMuted = !this.avPlayerMuted;
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : linearToPerceived(this.avPlayerVolume || 1));
      saveMuted(this.avPlayerMuted);
    } else if (this.video) {
      this.video.muted = !this.video.muted;
      saveMuted(this.video.muted);
    }
    this.updateVolumeUI();
    this.pushEvent("mute_toggled", {
      muted: this.usingAVPlayer ? this.avPlayerMuted : this.video?.muted,
    });
  },

  adjustVolume(delta) {
    let newVolume;

    if (this.usingAVPlayer && this.avPlayer) {
      newVolume = Math.max(0, Math.min(1, (this.avPlayerVolume || 1) + delta));
      this.avPlayerVolume = newVolume;
      if (!this.avPlayerMuted) {
        this.avPlayer.setVolume(linearToPerceived(newVolume));
      }
    } else if (this.video) {
      // Adjust UI volume, not backend volume
      const currentUIVolume = perceivedToLinear(this.video.volume);
      newVolume = Math.max(0, Math.min(1, currentUIVolume + delta));
      this.video.volume = linearToPerceived(newVolume);
    }

    saveVolume(newVolume);
    this.updateVolumeUI();
    this.pushEvent("volume_changed", { volume: Math.round((newVolume || 1) * 100) });
  },

  seek(seconds) {
    if (this.usingAVPlayer && this.avPlayer) {
      const currentTime = this.avPlayer.getCurrentTime();
      const duration = this.avPlayer.getDuration();
      if (duration > 0) {
        const newTime = Math.max(0, Math.min(duration, currentTime + seconds));
        this.avPlayer.seek(newTime);
      }
    } else if (this.video?.duration) {
      this.video.currentTime = Math.max(
        0,
        Math.min(this.video.duration, this.video.currentTime + seconds),
      );
    }
  },

  seekTo(time) {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayer.seek(time);
    } else if (this.video) {
      this.video.currentTime = time;
    }
  },

  getCurrentTime() {
    if (this.usingAVPlayer && this.avPlayer) {
      return this.avPlayer.getCurrentTime();
    }
    return this.video?.currentTime || 0;
  },

  getDuration() {
    let duration = 0;

    if (this.usingAVPlayer && this.avPlayer) {
      duration = this.avPlayer.getDuration();
    } else {
      duration = this.video?.duration || 0;
    }

    // Sanity check: if duration is absurd (>12 hours), use expected duration from DB
    const MAX_SANE_DURATION = 12 * 60 * 60; // 12 hours in seconds
    if (duration > MAX_SANE_DURATION && this.expectedDuration > 0) {
      return this.expectedDuration;
    }

    return duration;
  },

  isPaused() {
    if (this.usingAVPlayer && this.avPlayer) {
      return !this.avPlayer.isPlaying();
    }
    return this.video?.paused ?? true;
  },

  // ============================================
  // Watch Time Tracking
  // ============================================

  trackWatchTime() {
    // Guard: clear existing interval to prevent stacking
    if (this.watchInterval) {
      clearInterval(this.watchInterval);
    }
    // Run directly every 30s instead of checking every 1s
    this.watchInterval = setInterval(() => {
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      this.pushEvent("update_watch_time", { duration });
    }, 30000);
  },

  // ============================================
  // Lifecycle
  // ============================================

  destroyed() {
    this.cleanup();
    this.networkMonitor?.stop();
    this.nativeBufferManager?.stop();
    this.playerUI?.clearHideControlsTimeout();
    this.playerUI?.destroy();
    this.stopAVPlayerTimeUpdates();

    // Clear audio check timeout
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }

    // Clear next episode resources
    if (this.nextEpisodeCountdown) {
      clearInterval(this.nextEpisodeCountdown);
      this.nextEpisodeCountdown = null;
    }
    if (this.nextEpisodePreloader) {
      this.nextEpisodePreloader.destroy?.();
      this.nextEpisodePreloader = null;
    }

    // Clear buffering debounce
    if (this._bufferingDebounce) {
      clearTimeout(this._bufferingDebounce);
      this._bufferingDebounce = null;
    }

    if (this.keyboardManager) {
      this.keyboardManager.destroy();
      this.keyboardManager = null;
    }

    if (this.watchInterval) {
      clearInterval(this.watchInterval);
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      if (duration > 0) {
        this.pushEvent("update_watch_time", { duration });
      }
    }

    if (this.el) {
      this.el.__videoPlayerHook = null;
    }
  },
};

export default VideoPlayer;
