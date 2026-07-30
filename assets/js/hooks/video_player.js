import { KeyboardManager } from "../core/keyboard_manager";
import { playerLogger as log, setErrorReporter } from "../core/logger";
import {
  getCapabilitySummary,
  getCodecCapabilityReport,
  getMediaDecodingInfo,
} from "../media/codec_detector";
import { CodecAwareABR, getCodecRecommendation } from "../media/codec_priority";
import { NativeBufferManager } from "../media/native_buffer";
import { NetworkMonitor } from "../media/network_monitor";
import { getHls, isHlsJsSupported, isMpegtsSupported } from "../media/player_libs";
import {
  buildQualityProbeCandidates,
  detectQualityCodec,
  qualityVideoCodec,
} from "../media/quality_probe";
import { getFileExtension, getStreamType, StreamLoader } from "../media/stream_loader";
import {
  ContentType,
  FeatureFlags,
  getFeatureRecommendations,
  getStreamingConfig,
  selectStreamingMode,
} from "../media/streaming_config";
import { getWebCodecsCapabilityReport, isWebCodecsSupported } from "../media/webcodecs_decoder";
import { getMSEWorkerCapabilityReport, isMSEInWorkersSupported } from "../media/worker_mse";
import { createAspectRatioController } from "../player/aspect_ratio_controller";
import { createAudioController } from "../player/audio_controller";
import { audioOutputVolume } from "../player/audio_state";
import { selectEngine } from "../player/engine_selector";
import {
  createErrorReport,
  detectErrorPatterns,
  formatErrorForLog,
} from "../player/error_telemetry";
import { evaluateFallbackAttempt } from "../player/fallback_policy";
import {
  buildIosPlayerState,
  readIosPlayerState,
  writeIosPlayerState,
} from "../player/ios_playback_state";
import { LifecycleScope } from "../player/lifecycle_scope";
import { createMobileControls } from "../player/mobile_controls";
import {
  waitForNativeReady as awaitNativeReady,
  waitForNativeSeek as awaitNativeSeek,
  configureNativePlaybackElement as configureNativeElement,
} from "../player/native_playback_controller";
import { buildNativePlaybackSnapshot } from "../player/native_playback_snapshot";
import {
  nextEpisodeCountdownWidth,
  nextEpisodePath,
  parseNextEpisode,
  shouldTriggerNextEpisode,
} from "../player/next_episode";
import {
  getPlaybackResourcePolicy,
  hasWebCodecsHevcSupport,
  isAppleTouchDevice,
  isFirefoxBrowser,
  isIosPwaMode,
  isStandalonePwa,
  readEngineFlag,
  scheduleLowPriority,
} from "../player/playback_environment";
import { PlaybackSession } from "../player/playback_session";
import { clampSeekTime, relativeSeekTarget } from "../player/playback_time";
import { diagnoseError, runQuickDiagnostics } from "../player/player_diagnostics";
import {
  forgetRecommendedPlayer,
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
} from "../player/player_preferences";
import { PlayerUI } from "../player/player_ui";
import {
  findPortugueseTrack,
  formatTrackLabel,
  hasSubtitleInLanguage,
} from "../player/track_metadata";

// Lazy load AVPlayer only when needed
let AVPlayerWrapper = null;
let detectAudioIssue = null;
let avPlayerModulePromise = null;

async function loadAVPlayer() {
  if (!AVPlayerWrapper) {
    log.debug("Lazy loading AVPlayer module...");
    avPlayerModulePromise ||= import("../media/avplayer_wrapper").catch((error) => {
      avPlayerModulePromise = null;
      throw error;
    });
    const module = await avPlayerModulePromise;
    AVPlayerWrapper = module.AVPlayerWrapper;
    detectAudioIssue = module.detectAudioIssue;
    log.debug("AVPlayer module loaded");
  }
  return { AVPlayerWrapper, detectAudioIssue };
}

// Lazy load avbridge only when GIndex MKV/HEVC is selected. The
// avbridge bundle pulls in libavjs-webcodecs-bridge + mediabunny and
// crosses the 1 MB threshold once gzipped, so we keep it off the
// critical path.
let AvbridgeWrapper = null;
let avbridgeModulePromise = null;

async function loadAvbridge() {
  if (!AvbridgeWrapper) {
    log.debug("Lazy loading avbridge module...");
    avbridgeModulePromise ||= import("../media/avbridge_wrapper").catch((error) => {
      avbridgeModulePromise = null;
      throw error;
    });
    const module = await avbridgeModulePromise;
    AvbridgeWrapper = module.AvbridgeWrapper;
    log.debug("avbridge module loaded");
  }
  return { AvbridgeWrapper };
}

// Lazy load h265web only when explicitly opted in. h265web ships a
// 415 KB SDK wrapper that then fetches ~7 MB of WASM from
// `priv/static/vendor/h265web/` only after the engine_selector picks
// it. Keep that off the critical path.
let H265webWrapper = null;
let h265webModulePromise = null;

async function loadH265web() {
  if (!H265webWrapper) {
    log.debug("Lazy loading h265web module...");
    h265webModulePromise ||= import("../media/h265web_wrapper").catch((error) => {
      h265webModulePromise = null;
      throw error;
    });
    const module = await h265webModulePromise;
    H265webWrapper = module.H265webWrapper;
    log.debug("h265web module loaded");
  }
  return { H265webWrapper };
}

const readAvbridgeFlag = (el) => readEngineFlag(el, "avbridge");
const readH265webFlag = (el) => readEngineFlag(el, "h265web");

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
    this.updateVolumeUI();
    this.initPlayer();
    this.setupEventListeners();
    this.setupNetworkMonitor();
    this.setupKeyboardShortcuts();
    this.setupMediaSession();
    this.aspectRatioController = createAspectRatioController({
      root: this.el,
      video: this.video,
    });
    this.trackWatchTime();

    // Configure error reporter to send errors to backend
    setErrorReporter((event, data) => this.pushEventSafe(event, data));

    // Expose hook instance on element for child hooks (like ProgressBar) to access
    this.el.__videoPlayerHook = this;

    // Run diagnostics as low-priority work so startup playback and user
    // gestures are not competing with WebCodecs/codec probes on the main thread.
    this._startupDiagnosticsCancel = scheduleLowPriority(() => {
      if (!this._destroyed) this.runStartupDiagnostics();
    });
  },

  getPlaybackResourcePolicy() {
    return getPlaybackResourcePolicy();
  },

  /**
   * Run quick diagnostics at startup (non-blocking)
   * Helps detect issues early and inform backend of device capabilities
   */
  async runStartupDiagnostics() {
    try {
      const policy = this.getPlaybackResourcePolicy();
      const quickDiag = await runQuickDiagnostics();

      if (!quickDiag.allPassed) {
        log.warn(
          "[VideoPlayer] Some startup diagnostics failed:",
          quickDiag.results.filter((r) => !r.passed),
        );
      }

      // Detect advanced capabilities
      const advancedCapabilities = policy.shouldRunAdvancedDiagnostics
        ? await this.detectAdvancedCapabilities()
        : {
            skipped: true,
            reason: policy.reason,
            webCodecs: { supported: isWebCodecsSupported(), report: null },
            mseWorkers: {
              supported: isMSEInWorkersSupported(),
              report: getMSEWorkerCapabilityReport(),
            },
            codecRecommendation: null,
            featureRecommendations: null,
          };

      // Send capabilities to backend for analytics
      this.pushEventSafe("device_diagnostics", {
        quick: quickDiag,
        capabilities: getCapabilitySummary(),
        advanced: advancedCapabilities,
        resource_policy: policy,
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
    this.lifecycle = new LifecycleScope({
      onDisposeError: (error) => log.warn("[VideoPlayer] Lifecycle cleanup failed:", error),
    });

    // DOM elements
    this.video = this.el.querySelector("video");
    this.configureNativePlaybackElement();

    // Stream configuration
    this.streamUrl = this.el.dataset.streamUrl;
    this.proxyUrl = this.el.dataset.proxyUrl;
    this.contentType = this.el.dataset.contentType || "live";
    this.sourceType = this.el.dataset.sourceType || null;
    this.contentId = this.el.dataset.contentId;
    this.imdbId = this.el.dataset.imdbId || null;
    this.subtitlesEnabled = this.el.dataset.subtitlesEnabled !== "false";
    this.subtitleLang = this.el.dataset.subtitleLang || "pt-BR";
    this.subtitleOffsetMs = Number(this.el.dataset.subtitleOffsetMs || 0);
    this.mediaTitle = this.el.dataset.mediaTitle || document.title || "Streamix";
    this.mediaSubtitle = this.el.dataset.mediaSubtitle || "Streamix";
    this.initialMode = this.el.dataset.streamingMode || null;
    this.expectedDuration = parseInt(this.el.dataset.expectedDuration, 10) || 0;
    this.playerLifecycleLogs = this.el.dataset.playerLifecycleLogs === "true";

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
    this._nativeExternalSubtitleTrack = null;
    this._nativeExternalSubtitleReloading = false;
    this._subtitleOffsetReloadTimer = null;
    this._externalSubtitleBlobUrl = null;
    this._externalSubtitleLoadedFor = null;
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
    this.playbackSessionId = 0;
    this.playbackMetrics = new PlaybackSession();

    // PiP state
    this.pipActive = false;

    // Network monitor
    this.networkMonitor = null;

    // Keyboard manager
    this.keyboardManager = null;
    this.aspectRatioController = null;
    this.mobileControls = null;

    // AVPlayer fallback state
    this.avPlayer = null;
    this.usingAVPlayer = false;
    this.audioCheckTimeout = null;
    this.avPlayerAttempted = false;
    // One canonical audio state feeds every playback engine and the UI. It
    // remains independent from temporary native <video> resets during engine
    // switches, so muted/output state cannot drift across fallbacks.
    this.audioController = createAudioController({
      applyOutput: (snapshot) => this.applyAudioOutput(snapshot),
      render: ({ volume, muted }) => this.playerUI?.updateVolumeUI(volume, muted),
      saveVolume,
      saveMuted,
    });
    this.avPlayerTimeInterval = null;
    this.preferAVPlayer = false; // Manual audio compatibility mode

    // Avbridge (preferred GPU HEVC) state — engine_selector hands
    // work here for GIndex MKV when the runtime exposes WebCodecs
    // and the feature flag is on. We track `attempted` so a
    // fallback to AVPlayer does not immediately bounce back here on
    // re-init.
    this.avbridge = null;
    this.usingAvbridge = false;
    this.avbridgeAttempted = false;
    // Toggle via `data-feature-avbridge` on the container or
    // `localStorage["streamix:avbridge"]` for ad-hoc opt-in.
    this.featureFlagAvbridge = readAvbridgeFlag(this.el);

    // H265web (alt GPU HEVC; needs SAB + COOP+COEP) state — kept as
    // a separate engine so the operator can flip between strategies
    // without redeploying. Off by default; turn on via
    // `data-feature-h265web` once the headers are wired.
    this.h265web = null;
    this.usingH265web = false;
    this.h265webAttempted = false;
    this.h265webTimeInterval = null;
    this.featureFlagH265web = readH265webFlag(this.el);

    // Next episode state (for pre-fetch)
    const serializedNextEpisode = this.el.dataset.nextEpisode;
    this.nextEpisode = parseNextEpisode(serializedNextEpisode);
    if (serializedNextEpisode && !this.nextEpisode) {
      log.warn("[VideoPlayer] Failed to parse next episode data");
    }
    this.nextEpisodeShown = false;
    this.nextEpisodeCountdown = null;
    this.nextEpisodePreloader = null;

    // Advanced features state
    this.codecABR = null; // Codec-aware ABR controller
    this.advancedCapabilities = null; // Cached advanced capabilities
    this.preferredCodec = null; // User/auto selected codec preference

    // Native buffer manager (for MP4/MKV streams)
    this.nativeBufferManager = null;
    this.nativeTouchControls = false;
    this.lastTimelineSeekAt = 0;
    this._emergencyStopDone = false;
    this.iosPwaMode = isIosPwaMode();
    this._suspendingForIos = false;
    this._wasPlayingBeforeHidden = false;
    this._lastIosPwaTapAt = 0;
    this._resumeAfterNativeSeek = false;
  },

  loadPreferences() {
    const prefs = getPreferences(this.contentId);

    // Apply volume (prefs.volume is UI value, convert to perceived for backends)
    this.setCanonicalAudioState(prefs);
    this.applyAudioState();

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
    // Auto-hide controls needs the *real* playing state — when
    // AVPlayer is the active player the native <video> stays
    // paused, so without this override the control bar never
    // fades and the timeline sticks on top of the picture.
    this.playerUI.setIsPlayingFn(() => {
      if (this.usingAVPlayer && this.avPlayer) {
        return !!this.avPlayer._playing;
      }
      return !!(this.video && !this.video.paused);
    });

    // Setup retry button
    const retryBtn = this.el.querySelector(".retry-btn");
    if (retryBtn) {
      this.lifecycle.listen(retryBtn, "click", () => {
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

    this.pushEventSafe("streaming_mode_changed", {
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
        this.pushEventSafe("codec_abr_suggestion", {
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

    this.pushEventSafe("quality_changed", { quality, level: levelIndex });
  },

  updateQualityList() {
    if (!this.streamLoader) return;

    this.availableQualities = this.streamLoader.getQualityLevels();
    const currentLevel = this.streamLoader.getCurrentLevel();

    // Enhance quality list with codec information
    const enhancedQualities = this.availableQualities.map((q) => ({
      ...q,
      codec: detectQualityCodec(q),
    }));

    this.playerUI.updateQualityOptions(enhancedQualities, currentLevel, (level) =>
      this.setQuality(level),
    );

    // Include codec info in event
    this.pushEventSafe("qualities_available", {
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

    this.probeQualityDecodeCapabilities(enhancedQualities);
  },

  probeQualityDecodeCapabilities(qualities) {
    const policy = this.getPlaybackResourcePolicy();
    if (!policy.shouldRunAdvancedDiagnostics || !navigator.mediaCapabilities?.decodingInfo) {
      return;
    }

    const candidates = buildQualityProbeCandidates(qualities);

    if (candidates.length === 0) return;

    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = scheduleLowPriority(async () => {
      this._qualityCapabilitiesCancel = null;
      if (this._destroyed) return;

      const results = await Promise.all(
        candidates.map(async ({ quality, config }) => ({
          index: quality.index,
          height: quality.height,
          bitrate: quality.bitrate,
          codec: qualityVideoCodec(quality),
          decodingInfo: await getMediaDecodingInfo(config),
        })),
      );

      if (this._destroyed) return;

      this.qualityDecodeCapabilities = results;
      log.debug("[VideoPlayer] Quality decode capabilities:", results);
    });
  },

  // ============================================
  // Audio Track Selection
  // ============================================

  setAudioTrack(trackIndex) {
    if (this.usingAVPlayer && this.avPlayer) {
      this.setAVPlayerAudioTrack(trackIndex);
      return;
    }

    if (this.streamLoader) {
      this.streamLoader.setAudioTrack(trackIndex);
    }
    this.selectedAudioTrack = trackIndex;

    // Save preference
    saveAudioTrack(trackIndex, this.contentId);

    const track = this.audioTracks[trackIndex];
    this.pushEventSafe("audio_track_changed", {
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

    this.pushEventSafe("audio_tracks_available", {
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
    if (this._nativeExternalSubtitleTrack?.track) {
      this._nativeExternalSubtitleTrack.track.mode = trackIndex === -1 ? "disabled" : "showing";
    }
    this.selectedSubtitleTrack = trackIndex;

    // Save preference
    saveSubtitleTrack(trackIndex, this.contentId);

    const track = trackIndex >= 0 ? this.subtitleTracks[trackIndex] : null;
    this.pushEventSafe("subtitle_track_changed", {
      track: trackIndex,
      label:
        track?.label ||
        track?.name ||
        track?.lang ||
        (trackIndex === -1 ? "Desativado" : `Faixa ${trackIndex}`),
    });
  },

  async setSubtitleOffset(offsetMs) {
    const parsedOffset = Number(offsetMs);
    if (!Number.isFinite(parsedOffset)) return;

    this.subtitleOffsetMs = Math.max(-600_000, Math.min(600_000, Math.trunc(parsedOffset)));
    this.updateSubtitleOffsetLabel();

    if (this.usingAVPlayer && this.avPlayer) {
      this.applyAVPlayerSubtitleDelay();
      return;
    }

    if (!this._nativeExternalSubtitleTrack && !this._nativeExternalSubtitleReloading) return;

    const selectedTrack = this.selectedSubtitleTrack;
    clearTimeout(this._subtitleOffsetReloadTimer);
    this._subtitleOffsetReloadTimer = setTimeout(
      () => this.reloadNativeExternalSubtitle(selectedTrack),
      150,
    );
  },

  async reloadNativeExternalSubtitle(selectedTrack) {
    this._subtitleOffsetReloadTimer = null;

    if (this._nativeExternalSubtitleReloading) {
      this._subtitleOffsetReloadTimer = setTimeout(
        () => this.reloadNativeExternalSubtitle(selectedTrack),
        150,
      );
      return;
    }

    this._nativeExternalSubtitleReloading = true;
    this._nativeExternalSubtitleTrack?.remove();
    this._nativeExternalSubtitleTrack = null;
    this._externalSubtitleLoadedFor = null;

    if (this._externalSubtitleBlobUrl) {
      URL.revokeObjectURL(this._externalSubtitleBlobUrl);
      this._externalSubtitleBlobUrl = null;
    }

    try {
      await this.loadNativeExternalSubtitleIfAvailable(this.playbackSessionId, true);
      if (this._nativeExternalSubtitleTrack) {
        this.setSubtitleTrack(selectedTrack === -1 ? -1 : 0);
      } else {
        this.subtitleTracks = [];
        this.setSubtitleTrack(-1);
        this.playerUI.updateSubtitleOptions([], -1, (track) => this.setSubtitleTrack(track));
      }
    } finally {
      this._nativeExternalSubtitleReloading = false;
    }
  },

  updateSubtitleOffsetLabel() {
    const label = this.el.querySelector("#subtitle-sync-value");
    if (!label) return;

    const seconds = this.subtitleOffsetMs / 1_000;
    const value = Number.isInteger(seconds) ? String(seconds) : seconds.toFixed(1);
    label.textContent = `${seconds > 0 ? "+" : ""}${value}s`;
  },

  applyAVPlayerSubtitleDelay() {
    if (!this.avPlayer || typeof this.avPlayer.setSubtitleDelay !== "function") return;

    this.avPlayer.setSubtitleDelay(this.subtitleOffsetMs);
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

    this.pushEventSafe("subtitle_tracks_available", {
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

      this.pushEventSafe("pip_toggled", { active: this.pipActive });
    } catch (error) {
      console.error("PiP error:", error);
      this.pushEventSafe("pip_error", { message: error.message });
    }
  },

  isPiPSupported() {
    return document.pictureInPictureEnabled && !this.video?.disablePictureInPicture;
  },

  setupMediaSession() {
    if (!("mediaSession" in navigator)) return;

    try {
      if ("MediaMetadata" in window) {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: this.mediaTitle,
          artist: this.mediaSubtitle,
          album: "Streamix",
        });
      }

      navigator.mediaSession.setActionHandler("play", () => {
        if (this.isPaused()) this.togglePlayPause();
      });
      navigator.mediaSession.setActionHandler("pause", () => {
        if (!this.isPaused()) this.togglePlayPause();
      });
      navigator.mediaSession.setActionHandler("seekbackward", (event) => {
        this.seek(-(event.seekOffset || 10));
      });
      navigator.mediaSession.setActionHandler("seekforward", (event) => {
        this.seek(event.seekOffset || 10);
      });
      navigator.mediaSession.setActionHandler("seekto", (event) => {
        if (typeof event.seekTime === "number") this.seekTo(event.seekTime);
      });
      this.updateMediaSessionPlaybackState();
    } catch (error) {
      log.debug("[VideoPlayer] Media Session setup skipped:", error.message);
    }
  },

  updateMediaSessionPlaybackState() {
    if (!("mediaSession" in navigator)) return;

    try {
      navigator.mediaSession.playbackState = this.isPaused() ? "paused" : "playing";
    } catch (error) {
      log.debug("[VideoPlayer] Media Session state update skipped:", error.message);
    }
  },

  setupIosPwaTapControls() {
    if (!this.iosPwaMode) return;

    this.el.classList.add("ios-pwa-tap-playback");
    this._onIosPwaTap = (event) => {
      if (!this.shouldHandleIosPwaTap(event)) return;

      const now = Date.now();
      if (now - this._lastIosPwaTapAt < 350) return;
      this._lastIosPwaTapAt = now;

      if (!this.playerUI.controlsVisible) {
        this.playerUI.showControls();
        this.playerUI.scheduleHideControls();
        this.reportIosPwaTelemetry("controls_revealed", {
          target: event.target?.tagName || "unknown",
        });
        return;
      }

      const pausedBefore = this.isPaused();
      this.reportIosPwaTelemetry("center_tap_play_pause", {
        paused_before: pausedBefore,
        target: event.target?.tagName || "unknown",
      });
      this.togglePlayPause();
    };
    this.lifecycle.listen(this.el, "click", this._onIosPwaTap);
  },

  shouldHandleIosPwaTap(event) {
    if (event.defaultPrevented || event.button !== 0) return false;

    const target = event.target;
    if (!(target instanceof Element)) return false;

    return !target.closest(
      [
        "button",
        "a",
        "input",
        "select",
        "textarea",
        "label",
        "[role='button']",
        "#player-controls",
        "#progress-container",
        "#settings-menu",
        ".no-ios-pwa-tap",
      ].join(","),
    );
  },

  reportIosPwaTelemetry(event, extra = {}) {
    if (!this.iosPwaMode) return;

    this.pushEventSafe("ios_pwa_player_event", {
      event,
      content_id: this.contentId,
      content_type: this.contentType,
      source_type: this.sourceType,
      stream_type: this.currentStreamType,
      engine: this.usingAVPlayer ? "avplayer" : "native",
      paused: this.isPaused(),
      current_time: Math.round(this.getCurrentTime()),
      display_mode: "standalone",
      ...extra,
    });
  },

  // ============================================
  // Event Listeners
  // ============================================

  setupEventListeners() {
    // DOM Custom Events from UI Controls
    this.lifecycle.listen(this.el, "player:toggle-play", () => this.togglePlayPause());
    this.lifecycle.listen(this.el, "player:toggle-mute", () => this.toggleMute());
    this.lifecycle.listen(this.el, "player:toggle-fullscreen", () => this.toggleFullscreen());
    this.lifecycle.listen(this.el, "player:toggle-pip", () => this.togglePiP());
    this.lifecycle.listen(this.el, "player:seek-relative", (event) => {
      this.seek(Number(event.detail?.seconds));
    });
    this.lifecycle.listen(this.el, "player:set-speed", (e) => {
      const speed = parseFloat(e.detail?.speed || 1);
      this.setPlaybackRate(speed);
    });
    this.lifecycle.listen(this.el, "player:toggle-avplayer", () => this.toggleAVPlayerPreference());
    if (this.playerUI.elements.retryBtn) {
      this.lifecycle.listen(this.playerUI.elements.retryBtn, "click", () =>
        this.retryPlaybackFromError(),
      );
    }
    this.setupIosPwaTapControls();

    // Mobile Touch Support
    this.mobileControls = createMobileControls({
      root: this.el,
      controls: this.el.querySelector("#player-controls"),
      video: this.video,
      playerUI: this.playerUI,
      shouldUseNativeControls: () => this.nativeTouchControls || this.iosPwaMode,
      toggleFullscreen: () => this.toggleFullscreen(),
    });

    // Volume slider input
    const volumeSlider = this.el.querySelector("#volume-slider");
    if (volumeSlider) {
      this.lifecycle.listen(volumeSlider, "input", (e) => {
        const volume = parseInt(e.target.value, 10) / 100;
        this.setVolume(volume);
      });
    }

    // Video Element Events
    this.lifecycle.listenOptional(this.video, "play", () => {
      // Autoplay-blocked overlay must not survive playback started by any
      // other path (keyboard, watch party sync, HLS/AVPlayer retry races)
      this.playerUI.removePlayButton();
      this.playerUI.updatePlayPauseUI(false);
      this.persistIosPlaybackState({ userPaused: false, wasPlaying: true, reason: "play" });
    });
    this.lifecycle.listenOptional(this.video, "pause", () => {
      this.playerUI.updatePlayPauseUI(true);
      this.clearNativeBufferingState();
      this.persistIosPlaybackState({
        userPaused: !this._suspendingForIos && document.visibilityState !== "hidden",
        wasPlaying: false,
        reason: "pause",
      });
    });
    this.lifecycle.listenOptional(this.video, "play", () => this.updateMediaSessionPlaybackState());
    this.lifecycle.listenOptional(this.video, "pause", () =>
      this.updateMediaSessionPlaybackState(),
    );
    this.lifecycle.listenOptional(this.video, "ended", () => {
      this.updateMediaSessionPlaybackState();
      this.flushPlaybackMetrics("completed");
    });
    this.lifecycle.listenOptional(this.video, "volumechange", () =>
      this.handleNativeVolumeChange(),
    );
    this.lifecycle.listenOptional(this.video, "timeupdate", () => {
      this.updateTimeUI();

      // Safety net: if video time is advancing, loading should be hidden
      // Fixes "infinite loading" on live streams where playing/canplaythrough don't re-fire
      if (this.video && !this.video.paused && this.video.readyState >= 3) {
        this.playerUI.hideLoading();
        this.playbackMetrics?.markPlaying();
      }
    });
    this.lifecycle.listenOptional(this.video, "loadedmetadata", () => this.updateTimeUI());
    this.lifecycle.listenOptional(this.video, "ratechange", () =>
      this.playerUI.updateSpeedUI(this.video.playbackRate),
    );
    this.lifecycle.listenOptional(this.video, "progress", () => {
      this.updateBufferBar();

      // For live streams: if buffer is filling, stream is healthy → hide loading
      if (this.video && !this.video.paused && this.video.buffered.length > 0) {
        const bufferedEnd = this.video.buffered.end(this.video.buffered.length - 1);
        const bufferAhead = bufferedEnd - this.video.currentTime;
        if (bufferAhead > 1) {
          this.playerUI.hideLoading();
          this.playbackMetrics?.setBuffering(false);
        }
      }
    });

    // Fullscreen events. Stash the handler so `destroyed()` can
    // remove it — without that, every LiveView nav stacked one
    // more listener on `document` for the lifetime of the SPA.
    this._onFullscreenChange = () => this.playerUI.updateFullscreenUI(!!document.fullscreenElement);
    this.lifecycle.listen(document, "fullscreenchange", this._onFullscreenChange);
    this.lifecycle.listen(document, "webkitfullscreenchange", this._onFullscreenChange);

    this._onIosVisibilityChange = () => this.handleIosVisibilityChange();
    this.lifecycle.listen(document, "visibilitychange", this._onIosVisibilityChange);

    this._onPageShow = () => this.resumeIosPlaybackState();
    this.lifecycle.listen(window, "pageshow", this._onPageShow);

    this._onPageTeardown = (event) => {
      this.handleIosPageHide(event);
      if (this.iosPwaMode && event?.persisted) return;
      this.flushPlaybackMetrics("cancelled");
      this.emergencyStopPlayback();
    };
    this.lifecycle.listen(window, "pagehide", this._onPageTeardown, { capture: true });
    this.lifecycle.listen(window, "beforeunload", this._onPageTeardown, { capture: true });

    // LiveView commands
    this.handleEvent("set_quality", ({ level }) => this.setQuality(level));
    this.handleEvent("set_audio_track", ({ track }) => this.setAudioTrack(track));
    this.handleEvent("set_subtitle_track", ({ track }) => this.setSubtitleTrack(track));
    this.handleEvent("subtitle_offset_changed", ({ offset_ms: offsetMs }) =>
      this.setSubtitleOffset(offsetMs),
    );
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
    this.lifecycle.listenOptional(this.video, "enterpictureinpicture", () => {
      this.pipActive = true;
      this.pushEventSafe("pip_toggled", { active: true });
    });

    this.lifecycle.listenOptional(this.video, "leavepictureinpicture", () => {
      this.pipActive = false;
      this.pushEventSafe("pip_toggled", { active: false });
    });

    // Progress tracking for VOD
    if (this.contentType === "vod") {
      this.lifecycle.listenOptional(this.video, "timeupdate", () => this.reportProgress());
      this.lifecycle.listenOptional(this.video, "durationchange", () => {
        if (this.video.duration && Number.isFinite(this.video.duration)) {
          this.pushEventSafe("duration_available", {
            duration: Math.floor(this.video.duration),
          });
        }
      });
    }

    this.lifecycle.listenOptional(this.video, "seeking", () => {
      this.lastTimelineSeekAt = Date.now();
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
        this._bufferingDebounce = null;
      }
    });

    this.lifecycle.listenOptional(this.video, "seeked", () => {
      if (!this._resumeAfterNativeSeek) return;

      this._resumeAfterNativeSeek = false;
      this.video.play().catch((error) => {
        if (error.name === "AbortError") return;
        log.debug("[VideoPlayer] native post-seek play() skipped:", error.message);
      });
    });

    // Buffer health monitoring with debounce to prevent flickering
    this.lifecycle.listenOptional(this.video, "waiting", () => {
      // Debounce live buffering more aggressively; live TS/MSE often emits
      // sub-second waiting pulses while the next chunk is already arriving.
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
      }
      const seekGraceMs = this.contentType === "vod" ? 1600 : 0;
      const isRecentTimelineSeek = Date.now() - this.lastTimelineSeekAt < seekGraceMs;
      const bufferingDelay =
        this.contentType === "live" ? 650 : isRecentTimelineSeek ? seekGraceMs : 200;
      this._bufferingDebounce = setTimeout(() => {
        // Only show if still buffering
        if (
          this.video &&
          !this.video.paused &&
          this.video.readyState < 3 &&
          Date.now() - this.lastTimelineSeekAt >= seekGraceMs
        ) {
          this.playerUI.showLoading();
          this.pushEventSafe("buffering", { buffering: true });
          this.playbackMetrics?.setBuffering(true);
        }
      }, bufferingDelay);
    });

    this.lifecycle.listenOptional(this.video, "playing", () => {
      // Cancel any pending buffering indicator
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
        this._bufferingDebounce = null;
      }
      this.pushEventSafe("buffering", { buffering: false });
      this.playbackMetrics?.markPlaying();
      this.playerUI.hideLoading();
      this.playerUI.hideError();
    });

    // Also hide loading on canplaythrough (video exits buffering during playback)
    // The "playing" event doesn't fire when video exits buffering if already playing
    this.lifecycle.listenOptional(this.video, "canplaythrough", () => {
      if (this._bufferingDebounce) {
        clearTimeout(this._bufferingDebounce);
        this._bufferingDebounce = null;
      }
      this.pushEventSafe("buffering", { buffering: false });
      this.playbackMetrics?.setBuffering(false);
      this.playerUI.hideLoading();
    });
  },

  // ============================================
  // UI Update Helpers
  // ============================================

  applyAudioOutput({ outputVolume, muted }) {
    // Keep the native element synchronized even while it is hidden. That
    // makes a later AVPlayer -> native fallback inherit the same audio state.
    if (this.video) {
      this.video.volume = outputVolume;
      this.video.muted = muted;
    }

    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayer.setVolume(outputVolume);
    }

    if (this.usingH265web && this.h265web) {
      this.h265web.setVolume(outputVolume);
    }
  },

  applyAudioState() {
    this.audioController.applyOutput();
  },

  canonicalAudioState() {
    return this.audioController.getState();
  },

  setCanonicalAudioState(state) {
    this.audioController.replaceState(state);
  },

  updateVolumeUI() {
    this.audioController.render();
  },

  handleNativeVolumeChange() {
    if (!this.video || this.usingAVPlayer || this.usingH265web || !this.nativeTouchControls) {
      this.updateVolumeUI();
      return;
    }

    const changed = this.audioController.syncNativeState({
      outputVolume: this.video.volume,
      muted: this.video.muted,
    });

    if (changed) {
      this.playbackMetrics?.markMutedMismatch();
      return;
    }

    this.updateVolumeUI();
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
          this.pushEventSafe("diagnostic_suggestion", {
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
    this.audioController.setVolume(volume);
  },

  setPlaybackRate(rate) {
    if (!this.video) return;

    // iOS Safari with native HLS flushes the decoder on any playbackRate
    // change ≠ 1.0, producing a 50-100ms stall. When we're already in
    // "conservative sync" mode (i.e. the watch_party_sync hook detected
    // native HLS and is throttling its corrections), cap the user's
    // chosen speed at 1.0 — otherwise the stall stacks on top of every
    // drift correction and the video looks broken.
    const native = !!this.video.canPlayType?.("application/vnd.apple.mpegurl");
    const inWatchParty = !!window.streamixWatchPartyActive;

    if (native && inWatchParty && rate > 1.0) {
      this.video.playbackRate = 1.0;
      savePlaybackRate(1.0);
      this.pushEventSafe("playback_rate_changed", { rate: 1.0 });
      this.playerUI?.showNotice?.(
        "Velocidade variável não é suportada com HLS nativo do iOS durante watch party.",
      );
      return;
    }

    this.video.playbackRate = rate;
    savePlaybackRate(rate);
    this.pushEventSafe("playback_rate_changed", { rate });
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
        this.persistIosPlaybackState({ reason: "progress" });
      }

      this.pushEventSafe("progress_update", {
        current_time: currentTime,
        duration: duration,
        percent: Math.round((currentTime / duration) * 100),
      });
    }
  },

  persistIosPlaybackState(extra = {}) {
    if (!this.iosPwaMode || this.contentType !== "vod" || !this.contentId) return;

    const currentTime = Math.floor(this.getCurrentTime());
    const duration = Math.floor(this.getDuration());
    const paused = this.isPaused();
    const audioState = this.canonicalAudioState();
    const state = buildIosPlayerState(
      {
        contentId: this.contentId,
        path: `${window.location.pathname}${window.location.search}`,
        currentTime,
        duration,
        paused,
        muted: audioState.muted,
        volume: audioState.volume,
        playbackRate: this.video?.playbackRate ?? 1,
      },
      extra,
    );
    if (!state) return;

    if (currentTime > 0) {
      savePlaybackPosition(this.contentId, currentTime, duration);
    }

    if (!writeIosPlayerState(state)) {
      log.debug("[VideoPlayer] iOS PWA state storage unavailable");
    }
  },

  handleIosVisibilityChange() {
    if (!this.iosPwaMode || this.contentType !== "vod") return;

    if (document.visibilityState === "hidden") {
      const wasPlaying = !this.isPaused();
      this._suspendingForIos = true;
      this._wasPlayingBeforeHidden = wasPlaying;
      this.persistIosPlaybackState({ userPaused: false, wasPlaying, reason: "hidden" });
      return;
    }

    this._suspendingForIos = false;
    this.resumeIosPlaybackState();
  },

  handleIosPageHide(event) {
    if (!this.iosPwaMode || this.contentType !== "vod") return;
    const wasPlaying = !this.isPaused();
    this._suspendingForIos = true;
    this._wasPlayingBeforeHidden = wasPlaying;
    this.persistIosPlaybackState({
      userPaused: false,
      wasPlaying,
      reason: event?.persisted ? "pagehide-persisted" : "pagehide",
    });
  },

  resumeIosPlaybackState() {
    if (!this.iosPwaMode || this.contentType !== "vod" || !this.video) return;

    const state = readIosPlayerState(this.contentId);
    if (!state) return;

    const currentAudioState = this.canonicalAudioState();
    this.setCanonicalAudioState({
      volume: Number.isFinite(state.volume) ? state.volume : currentAudioState.volume,
      muted: typeof state.muted === "boolean" ? state.muted : currentAudioState.muted,
    });
    this.applyAudioState();

    if (Number.isFinite(state.playbackRate) && state.playbackRate > 0) {
      this.video.playbackRate = state.playbackRate;
    }

    if (state.time > 5 && Math.abs((this.video.currentTime || 0) - state.time) > 2) {
      try {
        this.video.currentTime = state.time;
      } catch (error) {
        log.debug("[VideoPlayer] iOS PWA restore seek failed:", error.message);
      }
    }

    if (state.userPaused) {
      this.video.pause();
      return;
    }

    if (state.wasPlaying || this._wasPlayingBeforeHidden) {
      this.video.play().catch((error) => {
        if (error.name !== "AbortError" && error.name !== "NotAllowedError") {
          log.debug("[VideoPlayer] iOS PWA resume play failed:", error.message);
        }
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

    if (shouldTriggerNextEpisode(currentTime, duration)) {
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
        countdownBar.style.width = `${nextEpisodeCountdownWidth(countdown)}%`;
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

    const path = nextEpisodePath(this.nextEpisode);
    if (!path) {
      log.warn("[VideoPlayer] Invalid next episode ID:", this.nextEpisode.id);
      return;
    }

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
      getHls()
        .then((Hls) => {
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
        })
        .catch((e) => {
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

  getNativeHlsSupport() {
    // canPlayType returns "", "maybe", or "probably" — anything truthy
    // counts. Check both the modern Apple MIME and the legacy spelling
    // (older Safari / iOS reported the latter). Probing the actual
    // <video> element is more honest than UA sniffing.
    return !!(
      this.video &&
      (this.video.canPlayType("application/vnd.apple.mpegurl") ||
        this.video.canPlayType("application/x-mpegURL"))
    );
  },

  setNativeTouchControls(enabled) {
    this.nativeTouchControls = enabled;
    this.playerUI?.setNativeControlsMode(enabled);

    if (!this.video) return;

    this.video.controls = enabled;
    this.video.toggleAttribute("controls", enabled);
    this.video.playsInline = true;
    this.video.webkitPlaysInline = true;
    this.video.setAttribute("playsinline", "");
    this.video.setAttribute("webkit-playsinline", "");
    this.video.setAttribute("x-webkit-airplay", "allow");
  },

  clearNativeBufferingState() {
    if (this._bufferingDebounce) {
      clearTimeout(this._bufferingDebounce);
      this._bufferingDebounce = null;
    }
    this.playerUI?.hideLoading();
    this.pushEventSafe("buffering", { buffering: false });
    this.playbackMetrics?.setBuffering(false);
  },

  buildEngineContext(recommendedPlayer) {
    const hasWebCodecs = hasWebCodecsHevcSupport();
    return {
      streamType: this.currentStreamType,
      sourceType: this.sourceType,
      recommendedPlayer,
      preferAVPlayer: this.preferAVPlayer,
      avPlayerAttempted: this.avPlayerAttempted,
      avbridgeAttempted: this.avbridgeAttempted,
      h265webAttempted: this.h265webAttempted,
      // `data-uhd-hevc` instead of `data-is-4k-hevc` because the JS
      // dataset DOM mapping doesn't uppercase the segment after a
      // digit, so `data-is-4k-hevc` reads back as `is-4kHevc` (with
      // a literal hyphen in the key) and trips on the obvious access.
      isUhdHevc: this.el?.dataset?.uhdHevc === "true",
      shouldPreferAVPlayerForLiveTs: this.shouldPreferAVPlayerForLiveTs(),
      capabilities: {
        hlsJs: isHlsJsSupported(),
        mpegts: isMpegtsSupported(),
        nativeHls: this.getNativeHlsSupport(),
        // Both alt engines target HEVC paths only; gate them on
        // WebCodecs availability so legacy browsers stay on AVPlayer.
        avbridge: this.featureFlagAvbridge && hasWebCodecs,
        h265web: this.featureFlagH265web && hasWebCodecs,
      },
    };
  },

  reportPlayerDebug(stage, extra = {}) {
    this.pushEventSafe("player_debug", {
      stage,
      current_stream_type: this.currentStreamType,
      content_type: this.contentType,
      source_type: this.sourceType,
      use_proxy: this.useProxy,
      current_url: this.currentUrl,
      stream_url: this.streamUrl,
      proxy_url: this.proxyUrl,
      prefer_avplayer: this.preferAVPlayer,
      using_avplayer: this.usingAVPlayer,
      avplayer_attempted: this.avPlayerAttempted,
      should_prefer_avplayer_for_live_ts: this.shouldPreferAVPlayerForLiveTs(),
      hls_supported: isHlsJsSupported(),
      mpegts_supported: isMpegtsSupported(),
      user_agent: navigator.userAgent,
      ...extra,
    });
  },

  reportPlayerLifecycle(stage, extra = {}) {
    if (stage === "player_engine_selected") {
      if (extra.fallback) {
        this.playbackMetrics?.recordFallback(extra.engine);
      } else {
        this.playbackMetrics?.selectEngine(extra.engine);
      }
    } else if (stage === "player_engine_fallback") {
      this.playbackMetrics?.recordFallback(extra.to);
    }

    this.pushEventSafe("player_lifecycle", {
      stage,
      session_id: this.playbackSessionId,
      engine: this.usingAVPlayer ? "avplayer" : "native",
      current_stream_type: this.currentStreamType,
      content_type: this.contentType,
      source_type: this.sourceType,
      using_avplayer: this.usingAVPlayer,
      native_touch_controls: this.nativeTouchControls,
      ...extra,
    });
  },

  pushEventSafe(event, payload) {
    if (this._destroyed || !this.el?.isConnected) return;

    try {
      this.pushEvent(event, payload);
    } catch (error) {
      log.debug(`[VideoPlayer] Ignoring ${event} after LiveView disconnect:`, error);
    }
  },

  flushPlaybackMetrics(outcome) {
    const metric = this.playbackMetrics?.finish(outcome);
    if (metric) this.pushEventSafe("client_telemetry", metric);
  },

  retryPlaybackFromError() {
    log.info("[VideoPlayer] Retrying playback from error screen");
    this.reportPlayerLifecycle("player_retry_from_error", {
      retry_count: this.retryCount,
      fallback_attempts: this.fallbackAttempts,
    });

    this.playerUI.hideError();
    this.playerUI.showLoading();
    this.retryCount = 0;
    this._hlsRecoveryAttempts = 0;
    this.fallbackAttempts = 0;
    this._switchingToAVPlayer = false;
    this.avPlayerAttempted = false;
    this.cleanup();
    this.initPlayer();
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
    this.reportPlayerLifecycle("player_cleanup");
    this.playbackSessionId += 1;
    this._metadataProbeCancel?.();
    this._metadataProbeCancel = null;
    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = null;

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
    if (this._nativeExternalSubtitleTrack) {
      this._nativeExternalSubtitleTrack.remove();
      this._nativeExternalSubtitleTrack = null;
    }
    clearTimeout(this._subtitleOffsetReloadTimer);
    this._subtitleOffsetReloadTimer = null;
    this._nativeExternalSubtitleReloading = false;
    if (this._externalSubtitleBlobUrl) {
      URL.revokeObjectURL(this._externalSubtitleBlobUrl);
      this._externalSubtitleBlobUrl = null;
    }
    this._externalSubtitleLoadedFor = null;
    if (this.avbridge) {
      this.avbridge.destroy().catch((err) => {
        log.debug("[VideoPlayer] avbridge cleanup threw:", err);
      });
      this.avbridge = null;
    }
    this.usingAvbridge = false;

    if (this.h265web) {
      this.h265web.destroy().catch((err) => {
        log.debug("[VideoPlayer] h265web cleanup threw:", err);
      });
      this.h265web = null;
    }
    this.usingH265web = false;
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }

    const avContainer = this.el?.querySelector("#avplayer-mount");
    if (avContainer) {
      avContainer.replaceChildren();
      avContainer.classList.add("hidden");
    }

    this.usingAVPlayer = false;
    this.avPlayerAttempted = false;
    this.setNativeTouchControls(false);

    if (this.video) {
      this.applyAudioState();
      this.resetNativeMediaElement({ restoreAudioState: true });
    }
  },

  resetNativeMediaElement({ restoreAudioState = false } = {}) {
    if (!this.video) return;

    const muted = this.video.muted;
    const volume = this.video.volume;

    this.video.pause();
    this.video.muted = true;
    this.video.removeAttribute("src");
    this.video.load();

    if (restoreAudioState) {
      this.video.muted = muted;
      this.video.volume = volume;
    }
  },

  emergencyStopPlayback() {
    if (this._emergencyStopDone) return;
    this._emergencyStopDone = true;

    try {
      this.video?.pause();
      if (this.video) {
        this.video.muted = true;
        this.video.removeAttribute("src");
        this.video.load();
      }
    } catch (error) {
      log.debug("[VideoPlayer] Emergency native teardown failed:", error);
    }

    try {
      this.avPlayer?.pause?.();
      this.avPlayer?.stop?.();
      this.avPlayer?.destroy?.();
    } catch (error) {
      log.debug("[VideoPlayer] Emergency AVPlayer teardown failed:", error);
    }

    try {
      this.avbridge?.pause?.();
      this.avbridge?.destroy?.();
    } catch (error) {
      log.debug("[VideoPlayer] Emergency avbridge teardown failed:", error);
    }

    try {
      this.h265web?.pause?.();
      this.h265web?.destroy?.();
    } catch (error) {
      log.debug("[VideoPlayer] Emergency h265web teardown failed:", error);
    }
  },

  beginPlaybackSession() {
    this.playbackSessionId += 1;
    return this.playbackSessionId;
  },

  isCurrentPlaybackSession(sessionId) {
    return !this._destroyed && sessionId === this.playbackSessionId;
  },

  configureNativePlaybackElement() {
    configureNativeElement(this.video);
  },

  shouldCheckNativeAudio() {
    if (this.contentType !== "vod") return false;

    // Xtream VOD ships H.264 + AAC by default through XUI, both of
    // which `<video>` decodes natively across every supported browser.
    // The audio-issue probe is meant to catch GIndex / unknown rips
    // that carry AC3/EAC3/DTS — running it on Xtream MP4 only adds
    // false positives (e.g. brief silent first frames) that then
    // wrongly demote the player to AVPlayer's libmedia WASM path,
    // which is the 30-55 s startup we are trying to avoid.
    if (this.sourceType === "xtream" && this.currentStreamType === "mp4") {
      return false;
    }

    return (
      this.sourceType === "gindex" ||
      this.currentStreamType === "mp4" ||
      this.currentStreamType === "mkv" ||
      this.currentStreamType === "unknown"
    );
  },

  traceNativeLifecycle(stage, sessionId, extra = {}) {
    if (!this.playerLifecycleLogs) return;

    const payload = {
      session_id: sessionId,
      ...buildNativePlaybackSnapshot(this.video),
      ...extra,
    };

    log.debug(`[VideoPlayer] ${stage}`, payload);
    this.reportPlayerLifecycle(stage, payload);
  },

  takeResumeTime(fallback = 0) {
    const savedTime =
      this.contentType === "vod" && this._savedPosition?.time > 0 ? this._savedPosition.time : null;

    if (savedTime != null) {
      this._savedPosition = null;
      return savedTime;
    }

    return fallback;
  },

  waitForNativeReady(sessionId) {
    return awaitNativeReady({
      video: this.video,
      isCurrent: () => this.isCurrentPlaybackSession(sessionId),
    });
  },

  waitForNativeSeek(sessionId, targetTime) {
    return awaitNativeSeek({
      video: this.video,
      targetTime,
      isCurrent: () => this.isCurrentPlaybackSession(sessionId),
      onSeekError: (error) =>
        log.debug("[VideoPlayer] Native seek before play failed:", error.message),
    });
  },

  async playNativeAfterResume(sessionId) {
    if (!this.video || !this.isCurrentPlaybackSession(sessionId)) return;

    const resumeTime = this.takeResumeTime();

    if (resumeTime > 0) {
      log.debug("Resuming from saved position before play:", resumeTime);
      this.traceNativeLifecycle("native_resume_prepare", sessionId, { resume_time: resumeTime });
      await this.waitForNativeReady(sessionId);
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      this.traceNativeLifecycle("native_resume_ready", sessionId, { resume_time: resumeTime });
      await this.waitForNativeSeek(sessionId, resumeTime);
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      this.traceNativeLifecycle("native_resume_seeked", sessionId, { resume_time: resumeTime });
    }

    if (!this.isCurrentPlaybackSession(sessionId)) return;

    try {
      this.traceNativeLifecycle("native_play_request", sessionId, { resume_time: resumeTime });
      await this.video.play();
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      this.traceNativeLifecycle("native_play_resolved", sessionId, { resume_time: resumeTime });
    } catch (e) {
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      if (e.name === "AbortError") return;
      this.traceNativeLifecycle("native_play_rejected", sessionId, {
        resume_time: resumeTime,
        error_name: e.name,
        error_message: e.message,
      });
      log.debug("Native play prevented:", e);
      this.playerUI.hideLoading();

      if (e.name === "NotSupportedError" && this.canTryAVPlayerForCurrentVod()) {
        log.debug("[VideoPlayer] Native play failed, AVPlayer fallback will be attempted");
        return;
      }

      if (e.name === "NotAllowedError") {
        this.playerUI.showPlayButton(() => this.playNativeAfterResume(this.playbackSessionId));
      } else {
        this.playerUI.showError(`Falha ao iniciar reproducao: ${e.message}`);
      }
    }
  },

  canTryAVPlayerForCurrentVod() {
    return (
      this.contentType === "vod" &&
      !this.avPlayerAttempted &&
      (this.currentStreamType === "mp4" ||
        this.currentStreamType === "mkv" ||
        this.sourceType === "gindex" ||
        this.currentStreamType === "unknown")
    );
  },

  // Idempotent stream loader factory. `cleanup()` nils out `streamLoader`
  // during player fallbacks, so `playWith*` methods call this before use
  // to avoid `TypeError: reading 'loadHls' of null`.
  ensureStreamLoader() {
    if (this.streamLoader) {
      this.streamLoader.updateSessionId(this.playbackSessionId);
      return this.streamLoader;
    }

    this.streamLoader = new StreamLoader({
      video: this.video,
      streamingMode: this.streamingMode,
      contentType: this.contentType,
      sessionId: this.playbackSessionId,
      onManifestParsed: (data, sessionId) => {
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        log.info("Manifest parsed, levels:", data.levels.length);
        this.playerUI.hideLoading();
        this.playerUI.hideError();
        this.updateQualityList();
        this.updateAudioTracks();
        this.updateSubtitleTracks();

        this.playNativeAfterResume(sessionId);
      },
      onError: (type, data, sessionId) => {
        if (this.isCurrentPlaybackSession(sessionId)) this.handleStreamError(type, data);
      },
      onLevelSwitched: (level, levelData, sessionId) => {
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        // Keep codec-aware ABR pointed at the codec the player is
        // actually decoding right now. Without this update,
        // `codecABR.suggestQuality()` keeps using the codec captured at
        // first level setup (always "h264" by default) and recommends
        // the wrong bandwidth/quality for HEVC/AV1 streams.
        if (this.codecABR && levelData?.codec) {
          this.codecABR.setCodec(levelData.codec);
        }

        const isAuto = this.manualQuality === null;
        this.pushEventSafe("quality_switched", {
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
      onAudioTracksUpdated: (_tracks, sessionId) => {
        if (this.isCurrentPlaybackSession(sessionId)) this.updateAudioTracks();
      },
      onSubtitleTracksUpdated: (_tracks, sessionId) => {
        if (this.isCurrentPlaybackSession(sessionId)) this.updateSubtitleTracks();
      },
      onFragLoaded: (bandwidth, sessionId) => {
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        this.networkMonitor?.addSample(bandwidth);
        // Feed bandwidth to codec-aware ABR
        if (this.codecABR) {
          this.codecABR.recordBandwidth(bandwidth / 1000); // Convert to kbps
        }
      },
      onMediaInfo: (_info, sessionId) => {
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        this.playerUI.hideLoading();
        this.playerUI.hideError();
      },
      onStatisticsInfo: (bps, sessionId) => {
        if (this.isCurrentPlaybackSession(sessionId)) this.networkMonitor?.addSample(bps);
      },
    });

    return this.streamLoader;
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

    this.flushPlaybackMetrics("restarted");
    this.cleanup();
    const sessionId = this.beginPlaybackSession();
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);
    this.playbackMetrics.begin({
      contentType: this.contentType,
      streamType: this.currentStreamType,
      displayMode: isStandalonePwa() ? "standalone" : "browser",
    });
    this.reportPlayerLifecycle("player_session_started", {
      session_id: sessionId,
      engine: this.currentStreamType,
    });

    // Create stream loader (idempotent — recreated lazily after cleanup during fallbacks)
    this.ensureStreamLoader();

    // Send codec capabilities to backend for optimal stream selection
    const capabilities = getCapabilitySummary();
    this.pushEventSafe("player_initializing", {
      stream_type: this.currentStreamType,
      streaming_mode: this.streamingMode,
      pip_supported: this.isPiPSupported(),
      capabilities, // Send codec support info to backend
    });

    // Check Device Codec Memory for recommended player (Netflix pattern)
    const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
    const recommendedPlayer = getRecommendedPlayer(contentKey);
    const engineContext = this.buildEngineContext(recommendedPlayer);
    const engine = selectEngine(engineContext);
    this.playbackMetrics.selectEngine(engine);

    log.debug("[VideoPlayer] Engine decision context", {
      currentStreamType: this.currentStreamType,
      contentType: this.contentType,
      sourceType: this.sourceType,
      recommendedPlayer,
      preferAVPlayer: this.preferAVPlayer,
      useProxy: this.useProxy,
      selectedEngine: engine,
      shouldPreferAVPlayerForLiveTs: engineContext.shouldPreferAVPlayerForLiveTs,
      hlsSupported: engineContext.capabilities.hlsJs,
      mpegtsSupported: engineContext.capabilities.mpegts,
      nativeHlsSupported: engineContext.capabilities.nativeHls,
      userAgent: navigator.userAgent,
    });
    this.reportPlayerDebug("init_player_decision", {
      recommended_player: recommendedPlayer,
      selected_engine: engine,
    });

    switch (engine) {
      case "avbridge":
        log.debug("Using avbridge (engine_selector decision)");
        this.playWithAvbridge();
        break;
      case "h265web":
        log.debug("Using h265web (engine_selector decision)");
        this.playWithH265web();
        break;
      case "avplayer":
        log.debug("Using AVPlayer (engine_selector decision)");
        this.tryAVPlayerFallback();
        break;
      case "native":
        log.debug("Using native playback (engine_selector decision)");
        this.playNative();
        break;
      case "hls-js":
        this.playWithHls();
        break;
      case "mpegts":
        this.playWithMpegts();
        break;
      case "mpegts-flv":
        this.playWithMpegts("flv");
        break;
      case "flv-unsupported":
        this.playerUI.showError("Reproducao FLV nao suportada neste navegador");
        break;
      default:
        log.warn("[VideoPlayer] Unknown engine decision:", engine);
        this.playNative();
    }
  },

  handleStreamError(type, data) {
    this.playbackMetrics?.recordError();

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
    this.pushEventSafe("player_error", {
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
        this.pushEventSafe("request_token_refresh", {});
        return;
      }

      switch (data.type) {
        case "networkError":
          if (data.details === "manifestLoadError" || data.details === "manifestParsingError") {
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
        this.reportPlayerDebug("mpegts_error_try_avplayer", {
          error_type: errorType,
          error_detail: errorDetail,
        });
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
    this.reportPlayerLifecycle("player_engine_selected", { engine: "hls-js" });

    if (!isHlsJsSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.playerUI.showError("HLS nao suportado neste navegador");
      }
      return;
    }

    this.hls = await this.ensureStreamLoader().loadHls(this.currentUrl);
  },

  async playWithAvbridge() {
    log.info("Playing with avbridge, url:", this.currentUrl);
    this.avbridgeAttempted = true;
    this.reportPlayerLifecycle("player_engine_selected", { engine: "avbridge" });

    const sessionId = this.playbackSessionId;
    const resumeTime = this.takeResumeTime();

    try {
      const { AvbridgeWrapper } = await loadAvbridge();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      this.avbridge = new AvbridgeWrapper({ video: this.video });
      await this.avbridge.load(this.currentUrl, { startTime: resumeTime });
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await this.avbridge.destroy().catch(() => {});
        this.avbridge = null;
        return;
      }

      this.usingAvbridge = true;
      this.playerUI.hideLoading();

      if (resumeTime > 0) {
        try {
          await this.avbridge.seek(resumeTime);
        } catch (seekErr) {
          log.warn("[Avbridge] seek-on-load failed, will try after play()", seekErr);
        }
      }
      await this.avbridge.play();
      this.playbackMetrics?.markPlaying();
    } catch (err) {
      log.warn("[Avbridge] init failed, falling back to AVPlayer:", err);
      this.playbackMetrics?.recordError();
      this.reportPlayerLifecycle("player_engine_fallback", {
        from: "avbridge",
        to: "avplayer",
        reason: err?.message || String(err),
      });
      try {
        await this.avbridge?.destroy?.();
      } catch {
        // best effort
      }
      this.avbridge = null;
      this.usingAvbridge = false;
      if (this.isCurrentPlaybackSession(sessionId)) {
        this.tryAVPlayerFallback();
      }
    }
  },

  async playWithH265web() {
    log.info("Playing with h265web, url:", this.currentUrl);
    this.h265webAttempted = true;
    this.reportPlayerLifecycle("player_engine_selected", { engine: "h265web" });

    const sessionId = this.playbackSessionId;
    const resumeTime = this.takeResumeTime();

    try {
      const { H265webWrapper } = await loadH265web();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      // h265web renders into its own canvas inside an opaque div. The
      // template ships `<div id="h265web-mount" phx-update="ignore">`
      // for exactly this reason — same `phx-update="ignore"` trick we
      // use for `avplayer-mount` so a LiveView patch does not wipe the
      // canvas mid-playback.
      const mountEl = this.el.querySelector("#h265web-mount");
      if (!mountEl) {
        throw new Error("h265web mount element (#h265web-mount) not found in template");
      }

      this.h265web = new H265webWrapper({
        video: this.video,
        mountEl,
        // Override base URL via `data-h265web-base-url` on the player
        // container — useful when the SDK is served from a different
        // origin than Phoenix (CDN, edge cache).
        baseUrl: this.el.dataset.h265webBaseUrl || undefined,
      });
      await this.h265web.load(this.currentUrl, {
        startTime: resumeTime,
        autoPlay: true,
      });
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await this.h265web.destroy().catch(() => {});
        this.h265web = null;
        return;
      }

      this.usingH265web = true;
      this.playerUI.hideLoading();

      // Resume + play. h265web.load already attaches the source, so we
      // just align `currentTime` and kick playback the way the native
      // path does. Any error throws → catch falls through to AVPlayer.
      if (resumeTime > 0) {
        try {
          await this.h265web.seek(resumeTime);
        } catch (seekErr) {
          log.warn("[H265web] seek-on-load failed, will try after play()", seekErr);
        }
      }
      await this.h265web.play();
      this.playbackMetrics?.markPlaying();
    } catch (err) {
      log.warn("[H265web] init failed, falling back to AVPlayer:", err);
      this.playbackMetrics?.recordError();
      this.reportPlayerLifecycle("player_engine_fallback", {
        from: "h265web",
        to: "avplayer",
        reason: err?.message || String(err),
      });
      try {
        await this.h265web?.destroy?.();
      } catch {
        // best effort
      }
      this.h265web = null;
      this.usingH265web = false;
      if (this.isCurrentPlaybackSession(sessionId)) {
        this.tryAVPlayerFallback();
      }
    }
  },

  async playWithMpegts(type = "mpegts") {
    if (type === "mpegts" && this.shouldPreferAVPlayerForLiveTs()) {
      log.debug("Skipping mpegts.js for live TS on Firefox, forcing AVPlayer");
      this.reportPlayerDebug("skip_mpegts_for_firefox_live_ts", { requested_type: type });
      this.tryAVPlayerFallback();
      return;
    }

    log.info("Playing with mpegts.js, type:", type, "url:", this.currentUrl);
    this.reportPlayerDebug("play_with_mpegts", { requested_type: type });
    const sessionId = this.playbackSessionId;
    this.reportPlayerLifecycle("player_engine_selected", { engine: type, session_id: sessionId });

    try {
      this.mpegtsPlayer = await this.ensureStreamLoader().loadMpegts(this.currentUrl, type);

      this.playNativeAfterResume(sessionId);

      this.video.addEventListener(
        "playing",
        () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.hideLoading();
          this.playerUI.hideError();
        },
        { once: true },
      );
    } catch (e) {
      console.error("mpegts.js initialization error:", e);
      this.playbackMetrics?.recordError();
      if (isHlsJsSupported()) {
        this.playWithHls();
      } else {
        this.playNative();
      }
    }
  },

  playNative() {
    const sessionId = this.playbackSessionId;
    log.info("Playing with native video element, url:", this.currentUrl);
    this.setNativeTouchControls(isAppleTouchDevice());
    this.configureNativePlaybackElement();
    this.reportPlayerLifecycle("player_engine_selected", {
      engine: "native",
      session_id: sessionId,
    });
    this.video.src = this.currentUrl;
    this.traceNativeLifecycle("native_source_attached", sessionId);

    const playHandler = () => {
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      log.debug("Native playback started");
      this.traceNativeLifecycle("native_playing", sessionId);
      this.playerUI.hideLoading();
      this.playerUI.hideError();
      this.video.removeEventListener("playing", playHandler);

      // Initialize Native Buffer Manager for MP4/MKV streams
      if (!this.nativeBufferManager && this.contentType === "vod") {
        this.nativeBufferManager = new NativeBufferManager(this.video, {
          onBufferHealthChange: (status) => {
            log.debug(
              `[NativeBuffer] Health: ${status.health}, buffer: ${status.bufferAhead.toFixed(1)}s`,
            );
          },
          onStall: (info) => {
            if (!info.isRealStall) {
              log.debug(`[NativeBuffer] Brief buffer wait #${info.totalStalls}`);
              return;
            }

            if (!info.shouldRecover) {
              log.debug(`[NativeBuffer] Stall observed #${info.totalStalls}`);
              return;
            }

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

      if (this.shouldCheckNativeAudio()) {
        this.checkAudioAndFallback(sessionId);
      }

      // For GIndex content, probe metadata in background to detect audio/subtitle tracks
      // This allows native player to start fast while we detect available tracks
      if (this.sourceType === "gindex") {
        this._metadataProbeCancel?.();
        this._metadataProbeCancel = scheduleLowPriority(
          () => {
            this._metadataProbeCancel = null;
            if (!this._destroyed && !this.usingAVPlayer) this.probeMetadataInBackground();
          },
          { timeout: 5000 },
        );
      }

      // Record successful native playback after 5s (confirms no fallback needed)
      // This helps Device Codec Memory learn that native works for this content type
      if (!this.shouldCheckNativeAudio()) {
        setTimeout(() => {
          if (
            this.isCurrentPlaybackSession(sessionId) &&
            !this.usingAVPlayer &&
            !this.video.paused
          ) {
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
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      if (this.usingAVPlayer || this.avPlayerAttempted) {
        log.debug("[VideoPlayer] Ignoring native video error - AVPlayer is active");
        return;
      }

      const error = this.video.error;
      this.playbackMetrics?.recordError();
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
    this.video.addEventListener(
      "loadedmetadata",
      () => {
        if (!this.isCurrentPlaybackSession(sessionId)) return;
        this.traceNativeLifecycle("native_metadata_loaded", sessionId);
        this.playerUI.hideLoading();

        if (this.sourceType === "torrent") {
          this.loadNativeExternalSubtitleIfAvailable(sessionId);
        }
      },
      { once: true },
    );

    this.playNativeAfterResume(sessionId).catch((e) => {
      if (e.name === "AbortError") return;
      log.debug("Native playback start failed:", e);
    });
  },

  // ============================================
  // Audio Detection and AVPlayer Fallback
  // ============================================

  async checkAudioAndFallback(sessionId) {
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
    }

    this.audioCheckTimeout = setTimeout(async () => {
      try {
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        this.traceNativeLifecycle("native_audio_check_start", sessionId);
        const { detectAudioIssue } = await loadAVPlayer();
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        const hasAudioIssue = await detectAudioIssue(this.video);
        if (!this.isCurrentPlaybackSession(sessionId)) return;

        this.traceNativeLifecycle("native_audio_check_result", sessionId, {
          has_audio_issue: hasAudioIssue,
        });

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
    const decision = evaluateFallbackAttempt(
      {
        attempts: this.fallbackAttempts,
        maxAttempts: this.maxFallbackAttempts,
        lastAttemptAt: this.lastFallbackTime,
        cooldowns: this.fallbackCooldowns,
      },
      Date.now(),
    );

    this.fallbackAttempts = decision.attempts;

    if (!decision.allowed) {
      const remaining = Math.ceil(decision.remainingMs / 1000);
      log.debug(
        `[VideoPlayer] Circuit breaker: ${decision.reason}, waiting ${remaining}s ` +
          `(attempt ${this.fallbackAttempts})`,
      );
    }

    return decision.allowed;
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

    log.debug("[VideoPlayer] Attempting AVPlayer fallback (seamless)", {
      currentStreamType: this.currentStreamType,
      contentType: this.contentType,
      proxyUrl: this.proxyUrl,
      streamUrl: this.streamUrl,
    });
    this.reportPlayerDebug("try_avplayer_fallback", {
      fallback_attempts: this.fallbackAttempts,
    });
    this.playerUI.hideError();

    const sessionId = this.beginPlaybackSession();
    const resumeTime = this.takeResumeTime(this.video.currentTime || 0);
    const wasPlaying = !this.video.paused || resumeTime > 0;
    this.reportPlayerLifecycle("player_engine_selected", {
      engine: "avplayer",
      session_id: sessionId,
      fallback: true,
    });

    this.video.pause();

    if (this._nativeErrorHandler) {
      this.video.removeEventListener("error", this._nativeErrorHandler);
    }

    try {
      // Lazy load AVPlayer
      const { AVPlayerWrapper } = await loadAVPlayer();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      // Use server-rendered mount (phx-update="ignore") so the
      // canvas survives LiveView patches in watch-party rooms.
      const avContainer = this.el.querySelector("#avplayer-mount");
      avContainer.replaceChildren();
      avContainer.classList.remove("hidden");

      this.video.classList.add("hidden");
      this.resetNativeMediaElement();
      if (this._nativeExternalSubtitleTrack) {
        this._nativeExternalSubtitleTrack.remove();
        this._nativeExternalSubtitleTrack = null;
      }
      this.subtitleTracks = [];

      if (this.avPlayer) {
        const oldAvPlayer = this.avPlayer;
        this.avPlayer = null;
        await oldAvPlayer.destroy();
        if (!this.isCurrentPlaybackSession(sessionId)) return;
      }

      const avPlayer = new AVPlayerWrapper({
        container: avContainer,
        onReady: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer ready");
        },
        onPlay: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer playing with audio support");
          this.playerUI.hideLoading();
          this.playerUI.updatePlayPauseUI(false);
          this.startAVPlayerTimeUpdates();
          this.playbackMetrics?.markPlaying();

          // Record successful AVPlayer playback for Device Codec Memory
          const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
          recordPlayerSuccess(contentKey, "avplayer", {
            sourceType: this.sourceType,
            streamType: this.currentStreamType,
          });
        },
        onPause: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer paused");
          this.playerUI.updatePlayPauseUI(true);
        },
        onError: (error) => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.error("[VideoPlayer] AVPlayer error:", error);
          this.playbackMetrics?.recordError();
          this.revertToNativePlayer();
        },
        onTimeUpdate: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.updateTimeUI();
        },
        onEnded: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer ended");
          this.playerUI.updatePlayPauseUI(true);
          this.stopAVPlayerTimeUpdates();
          this.flushPlaybackMetrics("completed");
        },
      });
      this.avPlayer = avPlayer;

      const avPlayerUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;

      const ext = getFileExtension(this.streamUrl, this.sourceType, this.currentStreamType);
      const isLive = this.contentType === "live";
      log.debug("[VideoPlayer] AVPlayer loading via:", avPlayerUrl, "ext:", ext, "isLive:", isLive);

      await avPlayer.load(avPlayerUrl, this.buildAVPlayerLoadOptions(ext, isLive));
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await avPlayer.destroy();
        return;
      }

      if (resumeTime > 0) {
        await avPlayer.seek(resumeTime);
        if (!this.isCurrentPlaybackSession(sessionId)) {
          await avPlayer.destroy();
          return;
        }
      }

      avPlayer.setVolume(audioOutputVolume(this.canonicalAudioState()));

      log.debug("[VideoPlayer] Calling AVPlayer play(), wasPlaying:", wasPlaying);
      await avPlayer.play();
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await avPlayer.destroy();
        return;
      }
      log.debug("[VideoPlayer] AVPlayer play() completed");

      this.usingAVPlayer = true;
      log.debug("[VideoPlayer] Seamless AVPlayer switch complete");

      // Detect available audio/subtitle tracks from AVPlayer
      this.detectAVPlayerTracks(sessionId);
    } catch (error) {
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      log.error("[VideoPlayer] AVPlayer fallback failed:", error);
      this.playbackMetrics?.recordError();

      // Forget the cached "avplayer" recommendation for this content
      // type so the next attempt re-evaluates engine_selector instead
      // of repeating the same broken AVPlayer load.
      const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
      if (contentKey) forgetRecommendedPlayer(contentKey);

      // revertToNativePlayer only swaps DOM visibility — it does NOT
      // assign `<video>.src` or kick off a load. When initPlayer picked
      // "avplayer" first (Device Codec Memory), we never set a native
      // src to fall back to, so the user was left staring at an empty
      // <video> tag. Re-run initPlayer so engine_selector recomputes
      // without the stale "avplayer" hint and picks native this time.
      // The this.avPlayerAttempted guard inside tryAVPlayerFallback
      // prevents looping back into AVPlayer.
      this.revertToNativePlayer();
      this.initPlayer();
    } finally {
      this._switchingToAVPlayer = false;
    }
  },

  /**
   * Detect and expose audio/subtitle tracks from AVPlayer
   */
  async detectAVPlayerTracks(sessionId = this.playbackSessionId) {
    if (!this.avPlayer) return;

    try {
      // Small delay to let AVPlayer fully initialize streams
      await new Promise((resolve) => setTimeout(resolve, 500));
      if (!this.isCurrentPlaybackSession(sessionId) || !this.avPlayer) return;

      // Get audio tracks
      const audioTracks = await this.avPlayer.getAudioTracks();
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      if (audioTracks && audioTracks.length > 0) {
        this.audioTracks = audioTracks.map((track, index) => ({
          index,
          id: track.id,
          label: formatTrackLabel(track),
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

        this.pushEventSafe("audio_tracks_available", {
          tracks: this.audioTracks,
          current: currentTrack,
        });

        log.debug("[VideoPlayer] AVPlayer audio tracks detected:", this.audioTracks);
      }

      // Get subtitle tracks
      const subtitleTracks = await this.avPlayer.getSubtitleTracks();
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      if (subtitleTracks && subtitleTracks.length > 0) {
        this.subtitleTracks = subtitleTracks.map((track, index) => ({
          index,
          id: track.id,
          label: formatTrackLabel(track),
          language: track.language || "",
        }));

        const currentTrack = subtitleTracks.findIndex((t) => t.selected);
        this.selectedSubtitleTrack = currentTrack;

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

        this.pushEventSafe("subtitle_tracks_available", {
          tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
          current: currentTrack,
        });

        log.debug("[VideoPlayer] AVPlayer subtitle tracks detected:", this.subtitleTracks);
      }
    } catch (e) {
      log.warn("[VideoPlayer] Failed to detect AVPlayer tracks:", e);
    }

    // Offer an external subtitle when the file ships none in the wanted
    // language (e.g. English-audio torrents). Runs after the embedded
    // probe so embedded tracks always take precedence.
    this.applyAVPlayerSubtitleDelay();
    await this.loadExternalSubtitleIfAvailable(sessionId);
  },

  /**
   * Fetch a PT-BR subtitle by IMDb id and inject it as an external track.
   * No-op without an imdb id, when the player lacks external-subtitle
   * support, or when the backend has nothing (204). Uses a Blob URL so
   * the player doesn't re-request (and to dodge CORS).
   */
  async loadExternalSubtitleIfAvailable(sessionId = this.playbackSessionId) {
    if (!this.imdbId || !this.avPlayer) return;
    if (typeof this.avPlayer.loadExternalSubtitle !== "function") return;
    if (hasSubtitleInLanguage(this.subtitleTracks, this.subtitleLang)) return;

    try {
      // AVPlayer applies the preference through its native subtitle-delay
      // control, so fetch an unshifted VTT and avoid applying the offset twice.
      const subtitleUrl = await this.fetchExternalSubtitleUrl(sessionId, 0);
      if (!subtitleUrl || !this.avPlayer) return;

      await this.avPlayer.loadExternalSubtitle({
        source: subtitleUrl,
        lang: this.subtitleLang,
        title: "Português (auto)",
      });

      // Re-probe so the new track shows up in the subtitle menu.
      if (this.isCurrentPlaybackSession(sessionId)) {
        await this.detectAVPlayerTracks(sessionId);
      }

      log.debug("[VideoPlayer] External subtitle loaded for", this.imdbId);
    } catch (e) {
      log.warn("[VideoPlayer] External subtitle load failed:", e);
    }
  },

  /**
   * Attach the external WebVTT to the native HTML5 player used by
   * ordinary torrent MP4s and expose it through Streamix's subtitle menu.
   */
  async loadNativeExternalSubtitleIfAvailable(sessionId = this.playbackSessionId, force = false) {
    if (!this.imdbId || !this.video || this.sourceType !== "torrent") return;

    const nativeTracks = Array.from(this.video.textTracks || []).map((track) => ({
      label: track.label,
      language: track.language,
    }));
    if (!force && hasSubtitleInLanguage(nativeTracks, this.subtitleLang)) return;

    try {
      const subtitleUrl = await this.fetchExternalSubtitleUrl(sessionId);
      if (!subtitleUrl || !this.video) return;

      const trackElement = document.createElement("track");
      trackElement.kind = "subtitles";
      trackElement.label = "Português (auto)";
      trackElement.srclang = this.subtitleLang;
      trackElement.src = subtitleUrl;
      this.video.appendChild(trackElement);
      this._nativeExternalSubtitleTrack = trackElement;

      this.subtitleTracks = [
        {
          index: 0,
          id: 0,
          label: trackElement.label,
          language: trackElement.srclang,
        },
      ];

      const preferredTrack = this.subtitlesEnabled && this._preferredSubtitleTrack !== -1 ? 0 : -1;
      this.setSubtitleTrack(preferredTrack);
      this.playerUI.updateSubtitleOptions(this.subtitleTracks, preferredTrack, (track) =>
        this.setSubtitleTrack(track),
      );

      this.pushEventSafe("subtitle_tracks_available", {
        tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
        current: preferredTrack,
      });

      log.debug("[VideoPlayer] Native external subtitle loaded for", this.imdbId);
    } catch (e) {
      log.warn("[VideoPlayer] Native external subtitle load failed:", e);
    }
  },

  /**
   * Fetch one subtitle per playback session and return a Blob URL that
   * either the native player or AVPlayer can consume without CORS.
   */
  async fetchExternalSubtitleUrl(sessionId, offsetMs = this.subtitleOffsetMs) {
    if (this._externalSubtitleLoadedFor === sessionId) return null;
    this._externalSubtitleLoadedFor = sessionId;

    const params = new URLSearchParams({
      lang: this.subtitleLang,
      offset_ms: String(offsetMs),
    });
    const url = `/api/subtitles/${encodeURIComponent(this.imdbId)}?${params}`;
    const res = await fetch(url, { headers: { accept: "text/vtt" } });
    if (res.status !== 200) return null; // 204 = no subtitle available
    if (!this.isCurrentPlaybackSession(sessionId)) return null;

    const vtt = await res.text();
    if (!vtt || !this.isCurrentPlaybackSession(sessionId)) return null;

    if (this._externalSubtitleBlobUrl) {
      URL.revokeObjectURL(this._externalSubtitleBlobUrl);
    }
    this._externalSubtitleBlobUrl = URL.createObjectURL(new Blob([vtt], { type: "text/vtt" }));
    return this._externalSubtitleBlobUrl;
  },

  buildAVPlayerLoadOptions(ext, isLive) {
    // GIndex 4K MKV is the only path that genuinely needs the heavier
    // load profile: large `moov`, MKV cluster probe, and the BEAM-side
    // proxy adds latency on top of upstream redirects. 2-min ceiling +
    // 8 MB preload + aggressive retry keeps the player alive on flaky
    // links. Everything else — including Xtream VOD MP4 — keeps the
    // libmedia defaults; the brief detour we took into a Xtream-side
    // preload tweak (89db59e, ce3b54f) actually regressed startup,
    // because a single 4-8 MB blocking fetch sits in TCP slow-start
    // while the upstream throttles us, so playback waited for the
    // whole prefetch before the first frame. libmedia's natural small
    // range walk is faster end-to-end and is the shape that always
    // worked in the field.
    const isHeavyGIndexMkv = !isLive && this.sourceType === "gindex" && ext === "mkv";

    if (isHeavyGIndexMkv) {
      return {
        ext,
        isLive,
        loadTimeoutMs: 120000,
        maxProbeDuration: 10,
        ioLoaderOptions: {
          preload: 8 * 1024 * 1024,
          retryCount: 8,
          retryInterval: 1,
        },
      };
    }

    return { ext, isLive };
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

      this.pushEventSafe("audio_track_changed", {
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
        this.pushEventSafe("subtitle_track_changed", { track: -1, label: "Desativado" });
      } else if (this.subtitleTracks[trackIndex]) {
        const track = this.subtitleTracks[trackIndex];
        await this.avPlayer.selectSubtitleTrack(track.id);
        this.selectedSubtitleTrack = trackIndex;
        saveSubtitleTrack(trackIndex, this.contentId);
        this.pushEventSafe("subtitle_track_changed", {
          track: trackIndex,
          label: track.label,
        });
        log.debug("[VideoPlayer] AVPlayer subtitle track changed to:", track.label);
      }
      this.applyAVPlayerSubtitleDelay();
    } catch (e) {
      log.error("[VideoPlayer] Failed to change AVPlayer subtitle track:", e);
    }
  },

  /**
   * Probe metadata in background.
   *
   * Old behavior spawned a 2nd full @libmedia/avplayer instance just to
   * enumerate tracks — ~1 s wall time, ~5 MB of WASM, full Web Audio
   * context. We replaced that with a server-side ffprobe cache:
   * `/api/gindex-tracks/:type/:id` returns `{audio, subtitle}` from a
   * jsonb column (or runs ffprobe + caches on miss, ~200 ms one-time).
   *
   * Cache miss fallback: if the API can't probe (file unreachable,
   * not GIndex, etc.), we silently bail — native playback keeps
   * working, the audio menu just shows whatever the native player
   * exposes.
   */
  async probeMetadataInBackground() {
    if (this.usingAVPlayer || this._metadataProbed || this._destroyed) return;
    this._metadataProbed = true;
    const policy = this.getPlaybackResourcePolicy();
    if (!policy.shouldProbeTracks) {
      log.debug("[VideoPlayer] Skipping track probe:", policy.reason);
      return;
    }

    const contentId = this.el.dataset.contentId;
    const contentType = this.contentType; // "movie" | "episode" | "live"
    if (!contentId || (contentType !== "movie" && contentType !== "episode")) return;

    log.debug("[VideoPlayer] Probing GIndex tracks via API...");

    try {
      const res = await fetch(`/api/gindex-tracks/${contentType}/${contentId}`, {
        headers: { Accept: "application/json" },
      });
      if (this._destroyed) return;
      if (!res.ok) {
        log.debug("[VideoPlayer] Track probe API returned", res.status, "— skipping");
        return;
      }
      const data = await res.json();
      if (this._destroyed) return;

      const audio = Array.isArray(data.audio) ? data.audio : [];
      const subtitle = Array.isArray(data.subtitle) ? data.subtitle : [];

      let preferredAudioTrack = 0;

      if (audio.length > 1) {
        // ffprobe gives us {index, codec, language, title, channels, ...};
        // map to the shape the player UI expects (re-numbered index 0..N
        // so the "select track 1" -> "select audio 1" mapping works
        // regardless of the underlying ffprobe stream index).
        this._probedAudioTracks = audio.map((track, index) => ({
          index,
          id: track.index,
          label: formatTrackLabel({
            index,
            label: track.title,
            language: track.language,
            codec: track.codec,
            channels: track.channels,
          }),
          language: track.language || "",
        }));

        log.debug("[VideoPlayer] Probed audio tracks:", this._probedAudioTracks);

        preferredAudioTrack = findPortugueseTrack(this._probedAudioTracks);
        log.debug("[VideoPlayer] Preferred Portuguese track index:", preferredAudioTrack);

        this.playerUI.updateAudioOptions(
          this._probedAudioTracks,
          preferredAudioTrack,
          (trackIndex) => this.handleProbedAudioTrackSelect(trackIndex),
        );

        this.pushEventSafe("audio_tracks_available", {
          tracks: this._probedAudioTracks,
          current: preferredAudioTrack,
        });
      }

      if (subtitle.length > 0) {
        this._probedSubtitleTracks = subtitle.map((track, index) => ({
          index,
          id: track.index,
          label: formatTrackLabel({
            index,
            label: track.title,
            language: track.language,
            codec: track.codec,
          }),
          language: track.language || "",
        }));

        log.debug("[VideoPlayer] Probed subtitle tracks:", this._probedSubtitleTracks);

        this.playerUI.updateSubtitleOptions(this._probedSubtitleTracks, -1, (trackIndex) =>
          this.handleProbedSubtitleTrackSelect(trackIndex),
        );

        this.pushEventSafe("subtitle_tracks_available", {
          tracks: [{ index: -1, label: "Desativado" }, ...this._probedSubtitleTracks],
          current: -1,
        });
      }

      if (this._destroyed) return;

      // Dual Audio auto-switch: when there's more than one audio track,
      // the native player can't reliably pick PT-BR — bridge to AVPlayer
      // with the preferred track selected.
      if (this._probedAudioTracks && this._probedAudioTracks.length > 1) {
        if (policy.avoidSpeculativeWork && !this.preferAVPlayer) {
          log.debug(
            "[VideoPlayer] Dual audio detected, waiting for user selection:",
            policy.reason,
          );
          return;
        }

        log.debug(
          "[VideoPlayer] Multiple audio tracks detected, auto-switching to AVPlayer with Portuguese track",
          preferredAudioTrack,
        );
        await new Promise((resolve) => setTimeout(resolve, 500));
        if (!this._destroyed) this.handleProbedAudioTrackSelect(preferredAudioTrack);
      }
    } catch (e) {
      log.debug("[VideoPlayer] Track probe API call failed:", e?.message);
    }
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

    const sessionId = this.beginPlaybackSession();
    this.playerUI.showLoading();

    try {
      // Stop native player fully; pause()+src="" can leave decoded audio alive.
      this.resetNativeMediaElement();

      if (this.avPlayer) {
        const oldAvPlayer = this.avPlayer;
        this.avPlayer = null;
        await oldAvPlayer.destroy();
        if (!this.isCurrentPlaybackSession(sessionId)) return;
      }

      const { AVPlayerWrapper } = await loadAVPlayer();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      // Use server-rendered mount (phx-update="ignore").
      const avContainer = this.el.querySelector("#avplayer-mount");
      avContainer.replaceChildren();
      avContainer.classList.remove("hidden");

      const avPlayer = new AVPlayerWrapper({
        container: avContainer,
        onReady: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer ready for track switch");
        },
        onError: (e) => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.error("[VideoPlayer] AVPlayer error:", e);
          this.playbackMetrics?.recordError();
        },
        onPlay: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(false); // false = not paused
          this.playerUI.hideLoading();
          this.startAVPlayerTimeUpdates();
          this.playbackMetrics?.markPlaying();
        },
        onPause: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(true); // true = paused
        },
        onTimeUpdate: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.updateTimeUI();
        },
        onEnded: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(true);
          this.stopAVPlayerTimeUpdates();
          this.flushPlaybackMetrics("completed");
        },
      });
      this.avPlayer = avPlayer;

      await avPlayer.init();
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await avPlayer.destroy();
        return;
      }

      // Load the stream (use proxyUrl if available, otherwise direct URL)
      const proxyUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;
      // For GIndex content, default to mkv since URL parsing is unreliable
      const ext =
        this.sourceType === "gindex"
          ? "mkv"
          : this.streamUrl.split(".").pop()?.split("?")[0] || "mkv";
      const isLive = this.contentType === "live";
      await avPlayer.load(proxyUrl, this.buildAVPlayerLoadOptions(ext, isLive));
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await avPlayer.destroy();
        return;
      }

      // Apply volume settings — wrapper exposes only `setVolume`
      // (no `mute()`). Use volume 0 for the muted state.
      avPlayer.setVolume(audioOutputVolume(this.canonicalAudioState()));

      // Mark as using AVPlayer
      this.usingAVPlayer = true;
      this.video.classList.add("hidden");

      // Seek to saved position
      if (seekTime > 0) {
        await avPlayer.seek(seekTime);
        if (!this.isCurrentPlaybackSession(sessionId)) {
          await avPlayer.destroy();
          return;
        }
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
        await avPlayer.play();
        if (!this.isCurrentPlaybackSession(sessionId)) {
          await avPlayer.destroy();
          return;
        }
      }

      // Start time updates
      this.startAVPlayerTimeUpdates();

      // Detect tracks from now-active AVPlayer
      this.detectAVPlayerTracks(sessionId);

      this.playerUI.hideLoading();
      log.debug("[VideoPlayer] Switched to AVPlayer with", trackType, "track", trackIndex);
    } catch (error) {
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      log.error("[VideoPlayer] Failed to switch to AVPlayer:", error);
      this.playerUI.hideLoading();
      this.playerUI.showError("Falha ao carregar faixas de áudio/legenda");
    } finally {
      this._switchingToAVPlayer = false;
    }
  },

  revertToNativePlayer() {
    log.debug("[VideoPlayer] Reverting to native player");
    this.reportPlayerLifecycle("player_engine_destroyed", { engine: "avplayer" });
    this.beginPlaybackSession();

    this.stopAVPlayerTimeUpdates();

    if (this.avPlayer) {
      this.avPlayer.destroy();
      this.avPlayer = null;
    }

    const avContainer = this.el.querySelector("#avplayer-mount");
    if (avContainer) {
      avContainer.replaceChildren();
      avContainer.classList.add("hidden");
    }

    this.video.classList.remove("hidden");
    this.usingAVPlayer = false;
    this.applyAudioState();
    this.updateVolumeUI();
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

    this.pushEventSafe("avplayer_preference_changed", { enabled: this.preferAVPlayer });
  },

  startAVPlayerTimeUpdates() {
    this.stopAVPlayerTimeUpdates();
    this._avPlayerAnimating = true;
    this._lastProgressUpdate = 0;
    this._lastUiUpdate = 0;

    // The progress bar UI does not need 60Hz updates — the human
    // eye stops noticing finer-than-100ms granularity on a moving
    // sub-pixel marker, and on phones running rAF at 60fps for the
    // whole movie just to redraw a 4-pixel-wide bar burned battery.
    // Throttle the visible UI tick to ~8Hz (every 125ms).
    const UI_TICK_MS = 125;

    const updateLoop = (timestamp) => {
      if (!this._avPlayerAnimating) return;

      if (this.usingAVPlayer && this.avPlayer) {
        if (timestamp - this._lastUiUpdate >= UI_TICK_MS) {
          this._lastUiUpdate = timestamp;
          this.updateTimeUI();
        }

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
        isMuted: () => this.canonicalAudioState().muted,
        isPiPSupported: () => this.isPiPSupported(),
        getPlaybackRate: () => this.video?.playbackRate || 1,
      },
    });

    this.keyboardManager.start();
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
      return;
    }

    if (this.video?.webkitDisplayingFullscreen) {
      this.video.webkitExitFullscreen?.();
      return;
    }

    if (isAppleTouchDevice() && this.video?.webkitEnterFullscreen) {
      this.video.webkitEnterFullscreen();
      return;
    }

    this.el.requestFullscreen?.() || this.video?.requestFullscreen?.();
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
    const audioState = this.audioController.toggleMute();
    this.pushEventSafe("mute_toggled", { muted: audioState.muted });
  },

  adjustVolume(delta) {
    const audioState = this.audioController.adjustVolume(delta);
    this.pushEventSafe("volume_changed", { volume: Math.round(audioState.volume * 100) });
  },

  seek(seconds) {
    if (this.contentType === "live") return;

    if (this.usingAVPlayer && this.avPlayer) {
      const currentTime = this.avPlayer.getCurrentTime();
      const duration = this.avPlayer.getDuration();
      const target = relativeSeekTarget(currentTime, seconds, duration);
      if (target === null) return;

      this.avPlayer.seek(target).catch((e) => {
        log.debug("[VideoPlayer] AVPlayer seek skipped:", e.message);
      });
    } else if (this.video) {
      const target = relativeSeekTarget(this.video.currentTime, seconds, this.getDuration());
      if (target !== null) this.seekNativeTo(target);
    }
  },

  seekTo(time) {
    if (this.contentType === "live") return;

    const target = clampSeekTime(time, this.getDuration());
    if (target === null) return;

    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayer.seek(target).catch((e) => {
        log.debug("[VideoPlayer] AVPlayer seek skipped:", e.message);
      });
    } else if (this.video) {
      this.seekNativeTo(target);
    }
  },

  seekNativeTo(time) {
    if (!this.video || this.contentType === "live") return;

    this.lastTimelineSeekAt = Date.now();
    this._resumeAfterNativeSeek = !this.video.paused;
    this.video.currentTime = time;
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
      this.pushEventSafe("update_watch_time", { duration });
    }, 30000);
  },

  // ============================================
  // Lifecycle
  // ============================================

  destroyed() {
    this.flushPlaybackMetrics("cancelled");
    this._destroyed = true;
    this.lifecycle?.dispose();
    this.lifecycle = null;
    this._startupDiagnosticsCancel?.();
    this._startupDiagnosticsCancel = null;
    this._metadataProbeCancel?.();
    this._metadataProbeCancel = null;
    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = null;
    this.cleanup();
    this.networkMonitor?.stop();
    this.nativeBufferManager?.stop();
    this.playerUI?.clearHideControlsTimeout();
    this.playerUI?.destroy();
    this.stopAVPlayerTimeUpdates();
    this.aspectRatioController?.destroy();
    this.aspectRatioController = null;
    this.mobileControls?.destroy();
    this.mobileControls = null;

    this._onFullscreenChange = null;
    this._onPageTeardown = null;
    this._onIosVisibilityChange = null;
    this._onPageShow = null;
    this._onIosPwaTap = null;

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

    if ("mediaSession" in navigator) {
      try {
        ["play", "pause", "seekbackward", "seekforward", "seekto"].forEach((action) => {
          navigator.mediaSession.setActionHandler(action, null);
        });
        navigator.mediaSession.playbackState = "none";
      } catch (error) {
        log.debug("[VideoPlayer] Media Session cleanup skipped:", error.message);
      }
    }

    if (this.watchInterval) {
      clearInterval(this.watchInterval);
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      if (duration > 0) {
        this.pushEventSafe("update_watch_time", { duration });
      }
    }

    if (this.el) {
      this.el.__videoPlayerHook = null;
    }
  },
};

export default VideoPlayer;
