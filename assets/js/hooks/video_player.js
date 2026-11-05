import { playerLogger as log, setErrorReporter } from "../core/logger.js";
import { getMediaDecodingInfo } from "../media/codec_detector.js";
import { CodecAwareABR } from "../media/codec_priority.js";
import { isHlsJsSupported, isMpegtsSupported } from "../media/player_libs.js";
import {
  buildQualityProbeCandidates,
  detectQualityCodec,
  qualityVideoCodec,
} from "../media/quality_probe.js";
import { FeatureFlags, getStreamingConfig } from "../media/streaming_config.js";
import { createAspectRatioController } from "../player/aspect_ratio_controller.js";
import { usesNativeAudioControls } from "../player/audio_controller.js";
import {
  ENGINE_ID,
  ENGINE_SELECTION,
  engineIdFromRuntime,
  PLAYBACK_STATE,
} from "../player/engine_contract.js";
import { evaluateFallbackAttempt } from "../player/fallback_policy.js";
import {
  configurationFromPlayerElement,
  probeMediaCapability,
} from "../player/media_capability_policy.js";
import { configureNativePlaybackElement as configureNativeElement } from "../player/native_playback_controller.js";
import { installPlaybackBridge } from "../player/playback_bridge.js";
import { createPlaybackEngineAdapter } from "../player/playback_engine_adapter.js";
import {
  getPlaybackResourcePolicy,
  hasWebCodecsHevcSupport,
  isAppleWebKitBrowser,
  isDirectStreamUrlAllowed,
  isFirefoxBrowser,
  scheduleLowPriority,
} from "../player/playback_environment.js";
import { consumePlaybackIntent } from "../player/playback_intent.js";
import { PlaybackRecoveryGuard } from "../player/playback_recovery_guard.js";
import { PlaybackStartupController } from "../player/playback_startup_controller.js";
import { playerComposition } from "../player/player_composition.js";
import {
  recordPlayerSuccess,
  savePlaybackPosition,
  savePreferAVPlayer,
} from "../player/player_preferences.js";
import { playerSessionLifecycle } from "../player/player_session_lifecycle.js";
import { ProviderEngineMemory } from "../player/provider_engine_memory.js";
import { sendQoeBeacon } from "../telemetry/qoe_beacon.js";

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
 * - Keyboard shortcuts (Netflix-style)
 * - Circuit breaker for fallback loops
 */
const VideoPlayer = {
  ...playerSessionLifecycle,
  ...playerComposition,
  mounted() {
    this.initializeState();
    this.initRecoveryGuard();
    this.loadPreferences();
    this.initUI();
    this.initStartupPresentation();
    this.initPlaybackCommandController();
    this.initPlaybackBrowserIntegration();
    this.updateVolumeUI();
    this.initPlaybackEngineActivation();
    this.setupEventListeners();
    this.setupSourceFailover();
    this.setupNetworkMonitor();
    this.setupKeyboardShortcuts();
    this.applyPartyControlPolicy();
    this.setupPlaybackSystemIntegration();
    this.aspectRatioController = createAspectRatioController({
      root: this.el,
      video: this.video,
    });
    this.trackWatchTime();

    // Configure error reporter to send errors to backend
    setErrorReporter((event, data) => this.pushEventSafe(event, data));

    // Expose hook instance on element for child hooks (like ProgressBar) to access
    this.el.__videoPlayerHook = this;

    // Engine-agnostic remote control for sibling hooks (watch party sync).
    // Without it they would poke the native <video>, which is idle whenever
    // AVPlayer is the active engine.
    this._disposePlaybackBridge = installPlaybackBridge(this.el, this);
    this.el.dispatchEvent(new CustomEvent("streamix:playback-ready", { bubbles: true }));

    // All lifecycle listeners, QoE consumers and engine-agnostic controls
    // must exist before a fast media source can emit its first events.
    this.syncPiPAvailability();
    void this.prepareMediaCapabilityProfile().finally(() => {
      if (!this._destroyed) this.initPlayer();
    });

    // Run diagnostics as low-priority work so startup playback and user
    // gestures are not competing with WebCodecs/codec probes on the main thread.
    this._startupDiagnosticsCancel = scheduleLowPriority(() => {
      if (!this._destroyed) this.runStartupDiagnostics();
    });
  },

  initStartupPresentation() {
    const intent = consumePlaybackIntent({ contentId: this.contentId });
    this.providerId = this.el.dataset.providerId || intent?.providerId || null;
    this.providerEngineMemory = new ProviderEngineMemory({
      getPlayback: () => ({
        playing: !this.isPaused() && !this.video?.seeking && !this._memorySeekTokens?.size,
        currentTime: this.getCurrentTime(),
        playbackRate: this.getPlaybackRate(),
      }),
      record: recordPlayerSuccess,
    });
    this._playbackMountedAt = intent?.startedAt ?? this._playbackMountedAt ?? performance.now();
    this.startupPresentation = new PlaybackStartupController({
      root: this.el,
      video: this.video,
      cover: intent?.cover,
      onMark: (mark) => {
        this.playbackMetrics?.markStage(mark);
        if (mark === "play") this.recoveryGuard?.resume();
      },
      onFrame: () => {
        this.playbackMetrics?.markFirstFrame();
        this.providerEngineMemory?.frame();
        this.recoveryGuard?.playing();
        if (this.isPaused()) this.recoveryGuard?.pause();
        this.playerUIController?.hideLoading();
      },
    });
    this.startupPresentation.begin();
  },

  initRecoveryGuard() {
    this.recoveryGuard = new PlaybackRecoveryGuard({
      onStable: () => {
        this.hlsRecoveryCoordinator?.reset();
        this.mpegtsRecoveryCoordinator?.reset();
        this.retryCount = 0;
        this.fallbackAttempts = 0;
      },
      onExhausted: (reason) => {
        this.cleanup();
        this.presentTerminalPlaybackError(
          "Não foi possível iniciar o vídeo. Tente novamente.",
          null,
          reason,
        );
      },
    });
    this.recoveryGuard.begin();
  },

  updated() {
    this.applyPartyControlPolicy();
  },

  getPlaybackResourcePolicy() {
    return getPlaybackResourcePolicy();
  },

  /**
   * Run quick diagnostics at startup (non-blocking)
   * Helps detect issues early and inform backend of device capabilities
   */
  async runStartupDiagnostics() {
    return this.diagnosticsController?.runStartup() ?? null;
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

  // ============================================
  // Network Monitoring
  // ============================================

  // The activation host is the only surface engine activations may touch.
  // Every member is an explicit callback so activations stay independent
  // from the hook object and can be exercised with fakes.

  // ============================================
  // Streaming Mode Management
  // ============================================

  switchStreamingMode(newMode) {
    if (newMode === this.streamingMode) return;

    log.debug(`Switching streaming mode: ${this.streamingMode} -> ${newMode}`);
    this.streamingMode = newMode;

    this.streamTransport?.updateStreamingMode(newMode);

    this.pushEventSafe("streaming_mode_changed", {
      mode: newMode,
      config: getStreamingConfig(newMode).name,
    });
  },

  // ============================================
  // Quality Selection
  // ============================================

  setQuality(levelIndex) {
    if (this.streamTransport?.current) {
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
      this.streamTransport.setQuality(levelIndex);
    }
    this.manualQuality = levelIndex === -1 ? null : levelIndex;

    const quality =
      levelIndex === -1
        ? "auto"
        : this.availableQualities[levelIndex]?.label || `Level ${levelIndex}`;

    this.pushEventSafe("quality_changed", { quality, level: levelIndex });
  },

  updateQualityList() {
    if (!this.streamTransport?.current) return;

    this.availableQualities = this.streamTransport.qualityLevels();
    const currentLevel = this.streamTransport.currentLevel();

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
    if (this.playerTrackController) {
      return this.playerTrackController.selectAudioTrack(trackIndex);
    }

    return this.trackOperations?.selectAudioTrack(trackIndex) ?? false;
  },

  updateAudioTracks() {
    if (this.playerTrackController) {
      return this.playerTrackController.refreshAudioTracks();
    }

    return this.trackOperations?.refreshAudioTracks() ?? [];
  },

  setSubtitleTrack(trackIndex) {
    if (this.playerTrackController) {
      return this.playerTrackController.selectSubtitleTrack(trackIndex);
    }

    return this.trackOperations?.selectSubtitleTrack(trackIndex) ?? false;
  },

  toggleSubtitles() {
    if (this.selectedSubtitleTrack >= 0) {
      this._lastActiveSubtitleTrack = this.selectedSubtitleTrack;
      return this.setSubtitleTrack(-1);
    }

    const targetTrack =
      this.playerTrackPresentationController?.resolveQuickSubtitleTrack(
        this._lastActiveSubtitleTrack,
      ) ?? 0;

    if (targetTrack === -1) return false;

    this._lastActiveSubtitleTrack = targetTrack;
    return this.setSubtitleTrack(targetTrack);
  },

  async setSubtitleOffset(offsetMs) {
    if (this.playerTrackController) {
      return this.playerTrackController.setSubtitleOffset(offsetMs);
    }

    return this.trackOperations?.setSubtitleOffset(offsetMs) ?? false;
  },

  async reloadNativeExternalSubtitle(...args) {
    if (this.playerTrackController) {
      return this.playerTrackController.reloadNativeExternalSubtitle(...args);
    }

    return this.trackOperations?.reloadNativeExternalSubtitle(...args) ?? false;
  },

  updateSubtitleTracks() {
    if (this.playerTrackController) {
      return this.playerTrackController.refreshSubtitleTracks();
    }

    return this.trackOperations?.refreshSubtitleTracks() ?? [];
  },

  async togglePiP() {
    return this.playbackBrowserIntegration?.togglePiP();
  },

  isPiPSupported() {
    return this.playbackBrowserIntegration?.isPiPSupported() ?? false;
  },

  isCanvasPlaybackActive() {
    return !!(
      this.usingAVPlayer ||
      this.usingAvbridge ||
      this.usingH265web ||
      this._switchingToAVPlayer
    );
  },

  getActivePlaybackEngine() {
    if (this.usingAVPlayer && this.avPlayer) return this.avPlayer;
    if (this.usingAvbridge && this.avbridge) return this.avbridge;
    if (this.usingH265web && this.h265web) return this.h265web;
    return this.mediaElementEngine;
  },

  activateHlsEngineFromLoader(sessionId = this.playbackSessionId, loader = this.streamLoader) {
    return (
      this.playbackEngineActivation
        ?.get(ENGINE_SELECTION.HLS_JS)
        ?.adoptLoaderEngine(sessionId, loader) ?? null
    );
  },

  setMediaElementEngine(engineId, engine, { ownsEngine = false } = {}) {
    if (!engine) throw new TypeError("setMediaElementEngine requires an engine");

    const current = this.mediaElementEngine;
    if (current?.id === engineId && !current.destroyed && current.wraps(engine)) {
      return current;
    }

    const next = createPlaybackEngineAdapter({ id: engineId, engine, ownsEngine });
    this.mediaElementEngine = next;

    if (this.playbackOrchestrator) {
      this.playbackOrchestrator.activateEngine(engineId, next);
    } else if (current) {
      current
        .destroy()
        .catch((error) =>
          log.debug("[VideoPlayer] Previous media element engine teardown failed:", error),
        );
    }

    return next;
  },

  usesNativePlaybackEvents() {
    return (
      !this._suppressNativePlaybackEvents &&
      !this.usingAVPlayer &&
      !this.usingH265web &&
      !this._switchingToAVPlayer
    );
  },

  setPiPState(active) {
    return this.playbackBrowserIntegration?.setPiPState(active) ?? false;
  },

  syncPiPAvailability() {
    return this.playbackBrowserIntegration?.syncPiPAvailability() ?? false;
  },

  disablePiPForCanvasPlayback() {
    return this.playbackBrowserIntegration?.disablePiPForCanvasPlayback();
  },

  setupPlaybackSystemIntegration() {
    return this.playbackBrowserIntegration?.setupPlaybackSystemIntegration() ?? false;
  },

  setPlaybackSystemState(state) {
    return this.playbackBrowserIntegration?.setPlaybackSystemState(state) ?? false;
  },

  updateMediaSessionPosition(options = {}) {
    return this.playbackBrowserIntegration?.updateMediaSessionPosition(options) ?? false;
  },

  handlePlaybackStarted() {
    this.providerEngineMemory?.progress();
    if (this._terminalPlaybackError) {
      this.setPlaybackSystemState("none");
      return;
    }

    if (this.startupPresentation?.hasFrame && !this.startupPresentation.awaitingFrame)
      this.recoveryGuard?.playing();

    this.observePlaybackState(PLAYBACK_STATE.PLAYING, "playback_started");
    this.setPlaybackSystemState("playing");
    this.playerUIController.hideAutoplayBlocked();
    this.playerUIController.hideEndedOverlay();
  },

  handlePlaybackPaused() {
    this.providerEngineMemory?.pause();
    this.recoveryGuard?.suspend();
    this.setPlaybackSystemState(this._terminalPlaybackError ? "none" : "paused");
  },

  handlePlaybackEnded() {
    this.setPlaybackSystemState("none");
    if (!this.nextEpisode) {
      this.playerUIController.showEndedOverlay(
        () => {
          this.seekTo(0);
          this.play();
        },
        () => {
          const closeBtn = this.el.querySelector("#player-close-btn");
          if (closeBtn) closeBtn.click();
          else if (window.history.length > 1) window.history.back();
          else window.location.href = "/browse";
        },
      );
    }
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

  applySourceFailover(payload) {
    if (this.recoveryGuard?.terminal) return;
    const streamUrl = payload?.stream_url;
    if (typeof streamUrl !== "string" || streamUrl.length === 0) return;

    this.reportPlayerLifecycle("source_failover_applied", {
      previous_content_id: this.contentId,
      next_content_id: payload.content_id,
      provider_id: payload.provider_id,
      failover_count: payload.failover_count,
    });

    this._sourceFailoverResumeTime = Number(payload.resume_time) || 0;
    this._savedPosition = null;
    this.streamUrl = streamUrl;
    this.proxyUrl = payload.proxy_url || streamUrl;
    this.sourceType = payload.source_type || this.sourceType;
    this.providerId = payload.provider_id ? String(payload.provider_id) : null;
    this._pendingEngineReason = "failover";
    this.contentId = String(payload.content_id);
    this.useProxy = true;
    this.currentUrl = null;
    this.currentStreamType = payload.stream_type || null;

    this.el.dataset.streamUrl = this.streamUrl;
    this.el.dataset.proxyUrl = this.proxyUrl;
    this.el.dataset.sourceType = this.sourceType;
    this.el.dataset.providerId = this.providerId || "";
    this.el.dataset.contentId = this.contentId;
    if (payload.stream_type) this.el.dataset.streamType = payload.stream_type;

    this.retryCount = 0;
    this.hlsRecoveryCoordinator?.reset();
    this.mpegtsRecoveryCoordinator?.reset();
    this.fallbackAttempts = 0;
    this._switchingToAVPlayer = false;
    this.avPlayerAttempted = false;
    this.avbridgeAttempted = false;
    this.h265webAttempted = false;
    this._emergencyStopDone = false;

    this.playerUIController.showRecovery();
    this.cleanup();
    this.initPlayer();
  },

  // ============================================
  // Event Listeners
  // ============================================

  bindLiveViewCommands() {
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
      // The server re-signed the stream token after a 401/403. Resume VOD
      // where it stopped instead of restarting from zero.
      log.debug("[VideoPlayer] Token refreshed, updating URLs");
      const resumeAt = this.contentType === "vod" ? this.video?.currentTime || 0 : 0;
      if (resumeAt > 0) this._savedPosition = { time: resumeAt };
      this.streamUrl = url;
      this.proxyUrl = proxyUrl || url;
      this.el.dataset.streamUrl = this.streamUrl;
      this.el.dataset.proxyUrl = this.proxyUrl;
      this.retryCount = 0;
      this.initPlayer();
    });
  },

  // ============================================
  // UI Update Helpers
  // ============================================

  showPlaybackError(message, hint = null, reason = "fatal_media_error") {
    if (this.recoveryGuard?.terminal) return;
    const failoverRequested = this.sourceFailoverController?.request({
      contentId: this.contentId,
      position: this.getCurrentTime(),
      reason: message,
    });

    if (failoverRequested) {
      this.observePlaybackState(PLAYBACK_STATE.RECOVERING, "source_failover");
      this._terminalPlaybackError = false;
      this.setPlaybackSystemState("none");
      this.playerUIController?.showRecovery();
      this.cleanup();
      return;
    }

    this.presentTerminalPlaybackError(message, hint, reason);
  },

  presentTerminalPlaybackError(message, hint = null, reason = "fatal_media_error") {
    this.providerEngineMemory?.clear();
    this.recoveryGuard?.finish();
    this.startupPresentation?.stop();
    this._terminalPlaybackError = true;
    this.observePlaybackState(PLAYBACK_STATE.TERMINAL, "terminal_error");
    this.setPlaybackSystemState("none");
    this.flushPlaybackMetrics("error", reason);
    this.playerUIController?.showError(message, hint);
  },

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
    if (
      !usesNativeAudioControls(this.video, {
        nativeControls: this.nativeTouchControls,
        canvasPlayback: this.usingAVPlayer || this.usingH265web,
      })
    ) {
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
    this.startupPresentation?.canvasProgress(this.getCurrentTime(), !this.isPaused());
    this.providerEngineMemory?.progress();
    return this.playerUIController?.updateTime() ?? null;
  },

  updateBufferBar() {
    return this.playerUIController?.updateBuffer() ?? null;
  },

  /**
   * Show error with optional automatic diagnostics (Netflix pattern)
   * @param {string} message - Error message to display
   * @param {Error|string} error - Original error for diagnostics
   * @param {boolean} runDiagnostics - Whether to run automatic diagnostics
   */
  async showErrorWithDiagnostics(message, error = null, runDiagnostics = false) {
    if (!this.diagnosticsController) {
      this.showPlaybackError(message);
      return null;
    }

    return this.diagnosticsController.showError(message, error, runDiagnostics);
  },

  setVolume(volume) {
    this.audioController.setVolume(volume);
  },

  getPlaybackCapabilities() {
    return this.playbackOrchestrator?.capabilities() ?? {};
  },

  getPlaybackTrackSnapshot() {
    return (
      this.playbackOrchestrator?.trackSnapshot() ?? {
        capabilities: {},
        audioTracks: [],
        subtitleTracks: [],
      }
    );
  },

  supportsPlaybackRateControl() {
    const capabilities = this.getPlaybackCapabilities();
    if (capabilities.setPlaybackRate || capabilities.getPlaybackRate) return true;
    return !this.usingAVPlayer && !this.usingH265web;
  },

  applyPartyControlPolicy() {
    return this.watchPartyPolicy?.applyControlPolicy() ?? false;
  },

  setWatchPartySyncHold(held) {
    if (this.watchPartyPolicy?.isViewer) {
      if (held) this.recoveryGuard?.suspend();
      else this.recoveryGuard?.resume();
    }
    return this.watchPartyPolicy?.setSyncHold(held) ?? true;
  },

  canControlPartyTransport(options = {}) {
    return this.watchPartyPolicy?.canControlTransport(options) ?? true;
  },

  rejectViewerTransportControl(options = {}) {
    return this.watchPartyPolicy?.rejectViewerTransportControl(options) ?? false;
  },

  setPlaybackRate(rate, options = {}) {
    return this.playbackCommandController?.setPlaybackRate(rate, options) ?? false;
  },
  reportProgress() {
    const currentTime = Math.floor(this.getCurrentTime());
    const duration = Math.floor(this.getDuration());

    if (!duration || duration <= 0) return;

    // Check for next episode trigger (30s before end or 90% progress)
    this.nextEpisodeController.check(currentTime, duration);

    if (Math.abs(currentTime - this.lastProgressReport) >= 10) {
      this.lastProgressReport = currentTime;

      // Save position to localStorage for resume later
      if (this.contentId && this.contentType === "vod") {
        savePlaybackPosition(this.contentId, currentTime, duration);
        this.iosPwaPlaybackController.persist({ reason: "progress" });
      }

      this.pushEventSafe("progress_update", {
        current_time: currentTime,
        duration: duration,
        percent: Math.round((currentTime / duration) * 100),
      });
    }
  },

  // ==================================================
  // URL Handling
  // ==================================================

  getEffectiveUrl(streamType) {
    const directUrlAllowed = isDirectStreamUrlAllowed(this.streamUrl, window.location.protocol);

    if (!directUrlAllowed && this.proxyUrl) {
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
    return (
      (this.currentStreamType === "ts" || this.currentStreamType === "xtream") &&
      this.contentType === "live" &&
      isFirefoxBrowser()
    );
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
    const allowed = this.watchPartyPolicy?.allowsNativeTouchControls() ?? true;
    enabled = enabled && allowed;
    this.nativeTouchControls = enabled;
    this.playerUIController?.setNativeControlsMode(enabled);

    if (!this.video) return;

    this.video.controls = enabled;
    this.video.toggleAttribute("controls", enabled);
    this.video.playsInline = true;
    this.video.webkitPlaysInline = true;
    this.video.setAttribute("playsinline", "");
    this.video.setAttribute("webkit-playsinline", "");
    this.video.setAttribute("x-webkit-airplay", "allow");
  },

  async prepareMediaCapabilityProfile() {
    try {
      const configuration = configurationFromPlayerElement(this.el, this.currentStreamType);

      this.mediaCapabilityProfile = await probeMediaCapability({
        configuration,
        decodingInfo: getMediaDecodingInfo,
        timeoutMs: 250,
      });
    } catch (error) {
      log.debug("[VideoPlayer] Media Capabilities probe failed:", error);
      this.mediaCapabilityProfile = null;
    }

    return this.mediaCapabilityProfile;
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
      preferNativeHls: isAppleWebKitBrowser(),
      mediaCapability: this.mediaCapabilityProfile,
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
    return this.diagnosticsController?.reportDebug(stage, extra) ?? null;
  },

  reportPlayerLifecycle(stage, extra = {}) {
    if (stage === "player_engine_selected") {
      this._memorySeekTokens?.clear();
      this.providerEngineMemory?.select({
        providerId: this.providerId,
        streamType: this.currentStreamType,
        engine: extra.engine,
        batchId: this.playbackMetrics?.active?.batchId,
      });
      this.startupPresentation?.attach({
        native: !["avplayer", "h265web"].includes(extra.engine),
      });
      if (extra.fallback) {
        this.playbackMetrics?.recordFallback(extra.engine, extra.reason || "fallback_codec");
        this.playbackOrchestrator?.recordFallback(extra.engine);
      } else {
        this.playbackMetrics?.selectEngine(extra.engine, extra.reason);
      }
    } else if (stage === "player_engine_fallback") {
      this.playbackMetrics?.recordFallback(extra.to, extra.reason || "fallback_codec");
      this.playbackOrchestrator?.recordFallback(extra.to);
    }

    this.pushEventSafe("player_lifecycle", {
      stage,
      session_id: this.playbackSessionId,
      engine: engineIdFromRuntime(this),
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

    if (event === "buffering") {
      this.el.dispatchEvent(
        new CustomEvent("streamix:buffering", {
          bubbles: true,
          detail: payload,
        }),
      );
    }

    try {
      this.pushEvent(event, payload);
    } catch (error) {
      log.debug(`[VideoPlayer] Ignoring ${event} after LiveView disconnect:`, error);
    }
  },

  flushPlaybackMetrics(outcome, reason, { beacon = false } = {}) {
    const metric = this.playbackMetrics?.finish(outcome, reason);
    if (!metric) return;
    // On the way out the socket may already be gone; the beacon gets there
    // anyway and the server keeps one copy of the sample.
    if (beacon) sendQoeBeacon(metric);
    this.pushEventSafe("client_telemetry", metric);
  },

  retryPlaybackFromError() {
    log.info("[VideoPlayer] Retrying playback from error screen");
    this.recoveryGuard?.begin();
    this.sourceFailoverController?.reset();
    this.pushEventSafe("reset_source_failover", {});
    this.reportPlayerLifecycle("player_retry_from_error", {
      retry_count: this.retryCount,
      fallback_attempts: this.fallbackAttempts,
    });

    this.flushPlaybackMetrics("restarted");
    this._playbackMountedAt = performance.now();
    this.startupPresentation?.begin();
    this.playerUIController.showRecovery();
    this.retryCount = 0;
    this.hlsRecoveryCoordinator?.reset();
    this.mpegtsRecoveryCoordinator?.reset();
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

  getPlaybackStateSnapshot() {
    return this.playbackOrchestrator?.snapshot().lifecycle ?? null;
  },

  observePlaybackState(nextState, reason, metadata = {}) {
    if (nextState === PLAYBACK_STATE.SEEKING) this.providerEngineMemory?.pause();
    if (nextState === PLAYBACK_STATE.STALLED || nextState === PLAYBACK_STATE.RECOVERING) {
      this.providerEngineMemory?.interrupt();
      this.recoveryGuard?.recover();
      if (nextState === PLAYBACK_STATE.RECOVERING || this.startupPresentation?.hasFrame)
        this.startupPresentation?.recover();
    }
    return this.playbackOrchestrator?.observe(nextState, reason, metadata) ?? null;
  },

  hlsRecoveryContext() {
    return this.streamTransport.recoveryContext({
      sessionId: this.playbackSessionId,
      url: this.currentUrl,
    });
  },

  async teardownStreamLoaderForTransition(sessionId) {
    if (!this.isCurrentPlaybackSession(sessionId)) return null;
    this.cleanup({ preservePlaybackState: true });
    const transitionSessionId = this.playbackSessionId;
    await this.streamTransport.awaitTeardown();
    return this.isCurrentPlaybackSession(transitionSessionId) ? transitionSessionId : null;
  },

  configureNativePlaybackElement(options = {}) {
    configureNativeElement(this.video, options);
  },

  takeResumeTime(fallback = 0) {
    const failoverTime = Number(this._sourceFailoverResumeTime);
    if (Number.isFinite(failoverTime) && failoverTime > 0) {
      this._sourceFailoverResumeTime = null;
      return failoverTime;
    }

    const savedTime =
      this.contentType === "vod" && this._savedPosition?.time > 0 ? this._savedPosition.time : null;

    if (savedTime != null) {
      this._savedPosition = null;
      return savedTime;
    }

    return fallback;
  },

  playNativeAfterResume(sessionId, resumeTime) {
    return this.nativeEngineActivation?.playAfterResume(sessionId, resumeTime) ?? Promise.resolve();
  },

  // Idempotent stream loader factory. `cleanup()` tears the loader down during
  // engine fallbacks, so activations call this before use.
  ensureStreamLoader() {
    return this.streamTransport.ensure();
  },

  // LiveView copies every own property of this object onto the hook instance,
  // which would freeze prototype getters into one-time values. Live accessors
  // are therefore defined on the instance once the collaborators exist.
  _definePlayerAccessors() {
    Object.defineProperty(this, "streamLoader", {
      configurable: true,
      enumerable: false,
      get: () => this.streamTransport?.current ?? null,
    });
  },

  handleStreamError(type, data) {
    if (this.recoveryGuard?.terminal) return;
    if ((type !== "hls" || data.fatal) && this.recoveryGuard && !this.recoveryGuard.attempt())
      return;
    return this.engineRecoveryPolicy?.handleStreamError(type, data);
  },

  recoverFromMpegtsError(data) {
    return this.engineRecoveryPolicy?.recoverFromMpegtsError(data) ?? Promise.resolve(false);
  },

  playWithHls() {
    return (
      this.playbackEngineActivation?.activate(ENGINE_SELECTION.HLS_JS) ?? Promise.resolve(false)
    );
  },

  playWithAvbridge() {
    return (
      this.playbackEngineActivation?.activate(ENGINE_SELECTION.AVBRIDGE) ?? Promise.resolve(false)
    );
  },

  playWithH265web() {
    return (
      this.playbackEngineActivation?.activate(ENGINE_SELECTION.H265WEB) ?? Promise.resolve(false)
    );
  },

  playWithMpegts(type = "mpegts") {
    const selection = type === "flv" ? ENGINE_SELECTION.MPEGTS_FLV : ENGINE_SELECTION.MPEGTS;
    return this.playbackEngineActivation?.activate(selection) ?? Promise.resolve(false);
  },

  playNative() {
    return (
      this.playbackEngineActivation?.activate(ENGINE_SELECTION.NATIVE) ?? Promise.resolve(false)
    );
  },

  /**
   * Check circuit breaker before attempting fallback (exponential backoff)
   */
  canAttemptFallback() {
    if (this.recoveryGuard?.terminal) return false;
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

  startWithAVPlayer(sessionId) {
    return (
      this.playbackEngineActivation?.activate(ENGINE_SELECTION.AVPLAYER, { sessionId }) ??
      Promise.resolve(false)
    );
  },

  tryAVPlayerFallback(reason = "fallback_codec") {
    return this.avPlayerEngineActivation?.tryFallback(reason) ?? Promise.resolve(false);
  },

  /**
   * Fetch a PT-BR subtitle by IMDb id and inject it as an external track.
   * No-op without an imdb id, when the player lacks external-subtitle
   * support, or when the backend has nothing (204). Uses a Blob URL so
   * the player doesn't re-request (and to dodge CORS).
   */
  async loadExternalSubtitleIfAvailable(...args) {
    if (this.playerTrackController) {
      return this.playerTrackController.loadExternalSubtitle(...args);
    }

    return this.trackOperations?.loadExternalSubtitle(...args) ?? false;
  },

  async loadNativeExternalSubtitleIfAvailable(...args) {
    if (this.playerTrackController) {
      return this.playerTrackController.loadNativeExternalSubtitle(...args);
    }

    return this.trackOperations?.loadNativeExternalSubtitle(...args) ?? false;
  },

  releaseExternalSubtitleSourceLease() {
    this.trackOperations?.releaseExternalSubtitleLease();
  },

  probeMetadataInBackground() {
    return this.trackProbeController?.probe() ?? Promise.resolve(false);
  },

  handleProbedAudioTrackSelect(trackIndex) {
    return this.trackProbeController?.selectAudioTrack(trackIndex) ?? Promise.resolve(false);
  },

  handleProbedSubtitleTrackSelect(trackIndex) {
    return this.trackProbeController?.selectSubtitleTrack(trackIndex) ?? Promise.resolve(false);
  },

  switchToAVPlayerWithTrack(trackType, trackIndex, seekTime, shouldPlay) {
    return (
      this.avPlayerEngineActivation?.switchWithTrack(trackType, trackIndex, seekTime, shouldPlay) ??
      Promise.resolve(false)
    );
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

  stopAVPlayerTimeUpdates() {
    return this.avPlayerEngineActivation?.stopTimeUpdates() ?? false;
  },

  // ============================================
  // Keyboard Shortcuts (YouTube-style)
  // ============================================

  setupKeyboardShortcuts() {
    return this.playbackBrowserIntegration?.setupKeyboardShortcuts() ?? false;
  },

  toggleFullscreen() {
    return this.playbackBrowserIntegration?.toggleFullscreen();
  },

  getNativePlaybackEngine() {
    if (this.mediaElementEngine?.id !== ENGINE_ID.NATIVE || this.mediaElementEngine.destroyed) {
      return null;
    }
    return this.mediaElementEngine;
  },

  trackManagedEngine(engineId, engine) {
    this.playbackOrchestrator?.activateEngine(engineId, engine, {
      registryOwnsEngine: false,
    });
    return engine;
  },

  getManagedPlaybackEngine() {
    if (this.usingAVPlayer && this.avPlayer) return this.avPlayer;
    if (this.usingAvbridge && this.avbridge) return this.avbridge;
    if (this.usingH265web && this.h265web) return this.h265web;
    return this.getNativePlaybackEngine();
  },

  async play(options = {}) {
    return this.playbackCommandController?.play(options);
  },

  async togglePlayPause(options = {}) {
    return this.playbackCommandController?.togglePlayPause(options);
  },

  toggleMute() {
    return this.playbackCommandController?.toggleMute();
  },

  adjustVolume(delta) {
    return this.playbackCommandController?.adjustVolume(delta);
  },

  seek(seconds, options = {}) {
    return this.playbackCommandController?.seek(seconds, options);
  },

  seekTo(time, options = {}) {
    return this.playbackCommandController?.seekTo(time, options);
  },

  seekNativeTo(time) {
    return this.playbackCommandController?.seekNativeTo(time) ?? false;
  },

  seekLiveTo(time) {
    return this.playbackCommandController?.seekLiveTo(time) ?? false;
  },

  getCurrentTime() {
    return this.playbackCommandController?.getCurrentTime() ?? 0;
  },

  getDuration() {
    return this.playbackCommandController?.getDuration() ?? 0;
  },

  getPlaybackRate() {
    return this.playbackCommandController?.getPlaybackRate() ?? 1;
  },

  isPaused() {
    return this.playbackCommandController?.isPaused() ?? true;
  },
  trackWatchTime() {
    // Guard: clear existing interval to prevent stacking
    if (this.watchInterval) {
      clearInterval(this.watchInterval);
    }
    // A 30s keepalive for the playback session. It used to send
    // `Date.now() - this.startTime`, but `startTime` is assigned nowhere, so
    // the value was always NaN — serialised as null, and the server raised on
    // it. The server ignores the payload now; sending a bogus number would only
    // invite someone to start trusting it again.
    this.watchInterval = setInterval(() => {
      this.pushEventSafe("update_watch_time", {});
    }, 30000);
  },

  // ============================================
  // Lifecycle
  // ============================================
};

export default VideoPlayer;
