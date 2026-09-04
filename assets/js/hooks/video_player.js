import { playerLogger as log, setErrorReporter } from "../core/logger";
import { getCapabilitySummary, getMediaDecodingInfo } from "../media/codec_detector";
import { CodecAwareABR } from "../media/codec_priority";
import { NetworkMonitor } from "../media/network_monitor";
import { isHlsJsSupported, isMpegtsSupported } from "../media/player_libs";
import {
  buildQualityProbeCandidates,
  detectQualityCodec,
  qualityVideoCodec,
} from "../media/quality_probe";
import { getStreamType } from "../media/stream_loader";
import {
  ContentType,
  FeatureFlags,
  getStreamingConfig,
  selectStreamingMode,
} from "../media/streaming_config";
import { isWebCodecsSupported } from "../media/webcodecs_decoder";
import { isMSEInWorkersSupported } from "../media/worker_mse";
import { createAspectRatioController } from "../player/aspect_ratio_controller";
import { createAudioController } from "../player/audio_controller";
import { audioOutputVolume } from "../player/audio_state";
import { createAvbridgeEngineActivation } from "../player/avbridge_engine_activation.js";
import { createAvPlayerEngineActivation } from "../player/avplayer_engine_activation.js";
import {
  assertEngineSelection,
  ENGINE_ID,
  ENGINE_SELECTION,
  engineIdFromRuntime,
  PLAYBACK_STATE,
} from "../player/engine_contract.js";
import { createEngineRecoveryPolicy } from "../player/engine_recovery_policy.js";
import { selectEngine } from "../player/engine_selector";
import {
  createErrorReport,
  detectErrorPatterns,
  formatErrorForLog,
} from "../player/error_telemetry";
import { evaluateFallbackAttempt } from "../player/fallback_policy";
import { createH265webEngineActivation } from "../player/h265web_engine_activation.js";
import { createHlsEngineActivation } from "../player/hls_engine_activation.js";
import { createHlsRecoveryCoordinator } from "../player/hls_recovery_coordinator.js";
import { createIosPwaPlaybackController } from "../player/ios_pwa_playback_controller.js";
import { LifecycleScope } from "../player/lifecycle_scope";
import {
  configurationFromPlayerElement,
  probeMediaCapability,
} from "../player/media_capability_policy";
import { createMediaEventBindings } from "../player/media_event_bindings.js";
import { createMobileControls } from "../player/mobile_controls";
import {
  createMpegtsEngineActivation,
  FLV_UNSUPPORTED_MESSAGE,
} from "../player/mpegts_engine_activation.js";
import { createMpegtsRecoveryCoordinator } from "../player/mpegts_recovery_coordinator.js";
import { NativeBufferingController } from "../player/native_buffering_controller";
import { createNativeEngineActivation } from "../player/native_engine_activation.js";
import { configureNativePlaybackElement as configureNativeElement } from "../player/native_playback_controller";
import { createNativeSubtitleController } from "../player/native_subtitle_controller.js";
import { NextEpisodeController } from "../player/next_episode_controller";
import { emitPlaybackEvent, installPlaybackBridge } from "../player/playback_bridge";
import { createPlaybackBrowserIntegration } from "../player/playback_browser_integration.js";
import { createPlaybackCommandController } from "../player/playback_command_controller";
import { createPlaybackEngineActivation } from "../player/playback_engine_activation.js";
import { createPlaybackEngineAdapter } from "../player/playback_engine_adapter.js";
import { PlaybackEngineTeardownQueue } from "../player/playback_engine_lifecycle";
import { createPlaybackEngineTransitionController } from "../player/playback_engine_transition_controller.js";
import {
  getPlaybackResourcePolicy,
  hasWebCodecsHevcSupport,
  isAppleWebKitBrowser,
  isDirectStreamUrlAllowed,
  isFirefoxBrowser,
  isStandalonePwa,
  scheduleLowPriority,
} from "../player/playback_environment";
import { createPlaybackOrchestrator } from "../player/playback_orchestrator.js";
import { createPlayerDiagnosticsController } from "../player/player_diagnostics_controller.js";
import {
  getPlaybackPosition,
  getPreferences,
  getRecommendedPlayer,
  saveAudioTrack,
  saveMuted,
  savePlaybackPosition,
  savePreferAVPlayer,
  saveSubtitleTrack,
  saveVolume,
} from "../player/player_preferences";
import { createInitialPlayerState } from "../player/player_state";
import { createPlayerTrackController } from "../player/player_track_controller.js";
import { createPlayerTrackPresentationController } from "../player/player_track_presentation_controller.js";
import { PlayerUI } from "../player/player_ui";
import { createPlayerUiController } from "../player/player_ui_controller.js";
import { createSourceFailoverController } from "../player/source_failover_controller.js";
import { createStreamTransport } from "../player/stream_transport.js";
import { createSubtitleSourceResolver } from "../player/subtitle_source_resolver.js";
import { createTrackOperations } from "../player/track_operations.js";
import { createTrackProbeController } from "../player/track_probe_controller.js";
import { createWatchPartyPlayerPolicy } from "../watch_party/player_policy.js";

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

  initializeState() {
    this.lifecycle = new LifecycleScope({
      onDisposeError: (error) => log.warn("[VideoPlayer] Lifecycle cleanup failed:", error),
    });

    this.video = this.el.querySelector("video");
    this.configureNativePlaybackElement();
    Object.assign(this, createInitialPlayerState(this.el));
    this.streamTransport = createStreamTransport({ host: this.buildStreamTransportHost() });
    this._definePlayerAccessors();
    this.watchPartyPolicy = createWatchPartyPlayerPolicy({
      enabled: this.partyMode === true,
      role: this.partyRole,
      root: this.el,
      getVideo: () => this.video,
      getManagedEngine: () => this.getManagedPlaybackEngine(),
      getNativeBufferManager: () => this.nativeBufferManager,
      setPlaybackSystemState: (state) => this.setPlaybackSystemState(state),
      showNotice: (message) => this.playerUI?.showNotice?.(message),
    });
    this.diagnosticsController = createPlayerDiagnosticsController({
      getResourcePolicy: () => this.getPlaybackResourcePolicy(),
      getErrorContext: () => ({
        contentType: this.contentType,
        streamType: this.currentStreamType,
        sourceType: this.sourceType,
      }),
      getDebugContext: () => ({
        current_stream_type: this.currentStreamType,
        content_type: this.contentType,
        source_type: this.sourceType,
        use_proxy: this.useProxy,
        current_url_present: Boolean(this.currentUrl),
        stream_url_present: Boolean(this.streamUrl),
        proxy_url_present: Boolean(this.proxyUrl),
        prefer_avplayer: this.preferAVPlayer,
        using_avplayer: this.usingAVPlayer,
        avplayer_attempted: this.avPlayerAttempted,
        should_prefer_avplayer_for_live_ts: this.shouldPreferAVPlayerForLiveTs(),
        hls_supported: isHlsJsSupported(),
        mpegts_supported: isMpegtsSupported(),
        user_agent: globalThis.navigator?.userAgent ?? null,
      }),
      initCodecAwareABR: (recommendation) => this.initCodecAwareABR(recommendation),
      pushEvent: (event, payload) => this.pushEventSafe(event, payload),
      showPlaybackError: (message) => this.showPlaybackError(message),
    });
    this.hlsRecoveryCoordinator = createHlsRecoveryCoordinator({
      onFailure: (error) => this.engineRecoveryPolicy?.reportHlsRecoveryFailure(error),
      onRecovering: (decision) =>
        this.observePlaybackState(PLAYBACK_STATE.RECOVERING, "hls_recovery", {
          recovery_attempt: decision.nextAttempts,
          recovery_operation: decision.operation,
          recovery_reason: decision.reason,
        }),
    });
    this.mpegtsRecoveryCoordinator = createMpegtsRecoveryCoordinator({
      maxNetworkAttempts: this.maxRetries,
      onDecision: (decision, data, snapshot) =>
        this.reportPlayerDebug("mpegts_recovery_decision", {
          action: decision.action,
          error_type: data?.errorType,
          error_detail: data?.errorDetail,
          network_attempts: snapshot.networkAttempts,
          recreate_attempts: snapshot.recreateAttempts,
        }),
      onRecovering: (decision, _data, snapshot) =>
        this.observePlaybackState(PLAYBACK_STATE.RECOVERING, "mpegts_recovery", {
          recovery_action: decision.action,
          recovery_reason: decision.reason,
          network_attempts: snapshot.networkAttempts,
          recreate_attempts: snapshot.recreateAttempts,
        }),
    });
    this.engineRecoveryPolicy = createEngineRecoveryPolicy({
      dependencies: { createErrorReport, detectErrorPatterns, formatErrorForLog },
      host: this.buildEngineRecoveryHost(),
    });
    this.avPlayerTeardownQueue = new PlaybackEngineTeardownQueue({
      onError: (error) => log.debug("[VideoPlayer] AVPlayer teardown failed:", error),
    });
    this.playbackEngineTransitionController = createPlaybackEngineTransitionController({
      beginSession: () => this.beginPlaybackSession(),
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      drainTeardown: () => this.avPlayerTeardownQueue.drain(),
      destroyEngine: (engine) => this.teardownAVPlayer(engine),
      onError: (operation, error, context) =>
        log.debug(`[VideoPlayer] Engine transition ${operation} failed:`, {
          error,
          key: context?.key,
          sessionId: context?.sessionId,
        }),
      onStateChange: (snapshot) => {
        this._switchingToAVPlayer = snapshot.active;
      },
    });

    // One canonical audio state feeds every playback engine and the UI. It
    // remains independent from temporary native <video> resets during engine
    // switches, so muted/output state cannot drift across fallbacks.
    this.audioController = createAudioController({
      applyOutput: (snapshot) => this.applyAudioOutput(snapshot),
      render: ({ volume, muted }) => this.playerUI?.updateVolumeUI(volume, muted),
      saveVolume,
      saveMuted,
    });
    this.iosPwaPlaybackController = createIosPwaPlaybackController({
      isEnabled: () => this.iosPwaMode,
      getContentType: () => this.contentType,
      getContentId: () => this.contentId,
      getVideo: () => this.video,
      getCurrentTime: () => this.getCurrentTime(),
      getDuration: () => this.getDuration(),
      isPaused: () => this.isPaused(),
      getAudioState: () => this.canonicalAudioState(),
      setAudioState: (state) => this.setCanonicalAudioState(state),
      applyAudioState: () => this.applyAudioState(),
      savePlaybackPosition,
      onStorageUnavailable: () => log.debug("[VideoPlayer] iOS PWA state storage unavailable"),
      onSeekError: (error) =>
        log.debug("[VideoPlayer] iOS PWA restore seek failed:", error.message),
      onPlayError: (error) => log.debug("[VideoPlayer] iOS PWA resume play failed:", error.message),
    });

    if (this.nextEpisodeParseFailed) {
      log.warn("[VideoPlayer] Failed to parse next episode data");
    }
    this.nextEpisodeController = new NextEpisodeController({
      episode: this.nextEpisode,
      onPlay: this.watchPartyPolicy?.isHost
        ? (episode) =>
            this.pushEventSafe("wp_next_episode", {
              id: episode.id,
              type: episode.type,
            })
        : null,
      root: this.el,
    });
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
    this.playerUIController = createPlayerUiController({
      emit: (event, payload) => this.pushEventSafe(event, payload),
      getBufferState: () => ({
        buffered: this.video?.buffered ?? null,
        currentTime: this.video?.currentTime ?? 0,
        duration: this.video?.duration ?? 0,
      }),
      getCurrentTime: () => this.getCurrentTime(),
      getDuration: () => this.getDuration(),
      initialPiPActive: this.pipActive,
      isPiPSupported: () => this.isPiPSupported(),
      isPlaying: () => !this.isPaused(),
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] UI ${operation} failed:`, error?.message || error),
      onPiPStateChange: (active) => {
        this.pipActive = active;
      },
      ui: this.playerUI,
      updateMediaSessionPosition: () => this.updateMediaSessionPosition(),
    });
    this.subtitleSourceResolver = createSubtitleSourceResolver({
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Subtitle source ${operation} failed:`, error),
    });
    this.nativeSubtitleController = createNativeSubtitleController({
      video: this.video,
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      resolveSource: ({ sessionId, offsetMs, force, language }) =>
        this.subtitleSourceResolver?.resolve({
          sessionId,
          imdbId: this.imdbId,
          language: language || this.subtitleLang,
          offsetMs,
          force,
        }),
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Native subtitle ${operation} failed:`, error),
    });
    this.playerTrackPresentationController = createPlayerTrackPresentationController({
      emit: (event, payload) => this.pushEventSafe(event, payload),
      getContentId: () => this.contentId,
      initialState: {
        audioTracks: this.audioTracks,
        selectedAudioTrack: this.selectedAudioTrack,
        selectedSubtitleTrack: this.selectedSubtitleTrack,
        subtitleOffsetMs: this.subtitleOffsetMs,
        subtitleTracks: this.subtitleTracks,
      },
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Track presentation ${operation} failed:`, error),
      onStateChange: (snapshot) => {
        this.audioTracks = [...snapshot.audioTracks];
        this.subtitleTracks = [...snapshot.subtitleTracks];
        this.selectedAudioTrack = snapshot.selectedAudioTrack;
        this.selectedSubtitleTrack = snapshot.selectedSubtitleTrack;
        this.subtitleOffsetMs = snapshot.subtitleOffsetMs;
      },
      renderAudioOptions: (tracks, currentTrack, onSelect) =>
        this.playerUI?.updateAudioOptions(tracks, currentTrack, onSelect),
      renderSubtitleOptions: (tracks, currentTrack, onSelect) =>
        this.playerUI?.updateSubtitleOptions(tracks, currentTrack, onSelect),
      renderSubtitleOffset: (label) => this.playerUI?.updateSubtitleOffsetLabel(label),
      saveAudioPreference: saveAudioTrack,
      saveSubtitlePreference: saveSubtitleTrack,
    });
    this.playerTrackPresentationController.presentSubtitleOffset(this.subtitleOffsetMs);

    this.trackOperations = createTrackOperations({ host: this.buildTrackOperationsHost() });
    this.playerTrackController = createPlayerTrackController({
      refreshAudioTracks: () => this.trackOperations.refreshAudioTracks(),
      refreshSubtitleTracks: () => this.trackOperations.refreshSubtitleTracks(),
      selectAudioTrack: (trackIndex) => this.trackOperations.selectAudioTrack(trackIndex),
      selectSubtitleTrack: (trackIndex) => this.trackOperations.selectSubtitleTrack(trackIndex),
      setSubtitleOffset: (offsetMs) => this.trackOperations.setSubtitleOffset(offsetMs),
      loadExternalSubtitle: (...args) => this.trackOperations.loadExternalSubtitle(...args),
      loadNativeExternalSubtitle: (...args) =>
        this.trackOperations.loadNativeExternalSubtitle(...args),
      reloadNativeExternalSubtitle: (...args) =>
        this.trackOperations.reloadNativeExternalSubtitle(...args),
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Track operation ${operation} failed:`, error),
    });
    this.trackProbeController = createTrackProbeController({
      host: {
        getContentId: () => this.el?.dataset?.contentId,
        getContentType: () => this.contentType,
        getResourcePolicy: () => this.getPlaybackResourcePolicy(),
        getSessionId: () => this.playbackSessionId,
        getVideo: () => this.video,
        hasAVPlayer: () => this.avPlayer != null,
        isDestroyed: () => this._destroyed === true,
        isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
        isSwitchingToAVPlayer: () => this._switchingToAVPlayer === true,
        isUsingAVPlayer: () => this.usingAVPlayer === true,
        prefersAVPlayer: () => this.preferAVPlayer === true,
        presentProbedTracks: (options) =>
          this.playerTrackPresentationController?.presentProbedTracks(options),
        setAudioTrack: (trackIndex) => this.setAudioTrack(trackIndex),
        setSubtitleTrack: (trackIndex) => this.setSubtitleTrack(trackIndex),
        switchToAVPlayerWithTrack: (trackType, trackIndex, seekTime, shouldPlay) =>
          this.switchToAVPlayerWithTrack(trackType, trackIndex, seekTime, shouldPlay),
        updateAudioTracks: () => this.updateAudioTracks(),
        updateSubtitleTracks: () => this.updateSubtitleTracks(),
      },
    });

    this.nativeBufferingController = new NativeBufferingController({
      contentType: this.contentType,
      emit: (event, payload) => this.pushEventSafe(event, payload),
      metrics: this.playbackMetrics,
      playerUI: this.playerUIController,
      video: this.video,
    });
  },

  // ============================================
  // Network Monitoring
  // ============================================

  initPlaybackCommandController() {
    this.playbackCommandController?.destroy();
    this.playbackCommandController = createPlaybackCommandController({
      getRoot: () => this.el,
      getVideo: () => this.video,
      getContentType: () => this.contentType,
      getExpectedDuration: () => this.expectedDuration,
      getManagedPlaybackEngine: () => this.getManagedPlaybackEngine(),
      getNativePlaybackEngine: () => this.getNativePlaybackEngine(),
      rejectViewerTransportControl: (options) => this.rejectViewerTransportControl(options),
      isWatchPartySyncHeld: () => this.watchPartyPolicy?.held === true,
      supportsPlaybackRateControl: () => this.supportsPlaybackRateControl(),
      isPartyMode: () => this.watchPartyPolicy?.enabled === true,
      getAudioController: () => this.audioController,
      getNativeBufferManager: () => this.nativeBufferManager,
      getNativeBufferingController: () => this.nativeBufferingController,
      getPlayerUiController: () => this.playerUIController,
      getPlayerUi: () => this.playerUI,
      setPlaybackSystemState: (state) => this.setPlaybackSystemState(state),
      updateMediaSessionPosition: (options) => this.updateMediaSessionPosition(options),
      pushEvent: (event, payload) => this.pushEventSafe(event, payload),
      emitPlaybackEvent,
      onDebug: (...args) => log.debug(...args),
      onError: (...args) => log.error(...args),
    });
  },

  initPlaybackBrowserIntegration() {
    this.playbackBrowserIntegration?.destroy();
    this.playbackBrowserIntegration = createPlaybackBrowserIntegration({
      root: this.el,
      video: this.video,
      commands: this.playbackCommandController,
      presentation: this.playerUIController,
      getCanvasPlaybackActive: () => this.isCanvasPlaybackActive(),
      getContentType: () => this.contentType,
      getMuted: () => this.canonicalAudioState().muted,
      isPlayerDestroyed: () => this._destroyed,
      metadata: {
        title: this.mediaTitle,
        artist: this.mediaSubtitle,
        album: "Streamix",
      },
      emit: (event, payload) => this.pushEventSafe(event, payload),
      onError: (operation, error) =>
        log.debug(
          `[VideoPlayer] Browser integration ${operation} skipped:`,
          error?.message || error,
        ),
    });
    this.playbackBrowserIntegration.start();
  },

  // The activation host is the only surface engine activations may touch.
  // Every member is an explicit callback so activations stay independent
  // from the hook object and can be exercised with fakes.
  buildPlaybackEngineActivationHost() {
    return {
      applyAudioState: () => this.applyAudioState(),
      canAttemptFallback: () => this.canAttemptFallback(),
      cancelNativeAudioCheck: () => this.nativeEngineActivation?.cancelAudioCheck(),
      clearStreamLoader: (loader) => this.streamTransport?.release(loader),
      detachNativeErrorHandler: () => this.nativeEngineActivation?.detachErrorHandler(),
      disablePiPForCanvasPlayback: () => this.disablePiPForCanvasPlayback(),
      emitPlaybackEvent: (event) => emitPlaybackEvent(this.el, event),
      ensureStreamLoader: () => this.ensureStreamLoader(),
      flushPlaybackMetrics: (outcome) => this.flushPlaybackMetrics(outcome),
      getAVPlayer: () => this.avPlayer,
      getAVPlayerMount: () => this.el?.querySelector("#avplayer-mount") ?? null,
      getAvbridge: () => this.avbridge,
      getContentType: () => this.contentType,
      getCurrentUrl: () => this.currentUrl,
      getFallbackAttempts: () => this.fallbackAttempts,
      getH265web: () => this.h265web,
      getH265webBaseUrl: () => this.el?.dataset?.h265webBaseUrl || null,
      getH265webMount: () => this.el?.querySelector("#h265web-mount") ?? null,
      getNativeBufferManager: () => this.nativeBufferManager,
      getNativeBufferingController: () => this.nativeBufferingController,
      getNativeHlsSupport: () => this.getNativeHlsSupport(),
      getNativePlaybackEngine: () => this.getNativePlaybackEngine(),
      getOutputVolume: () => audioOutputVolume(this.canonicalAudioState()),
      getPresentation: () => this.playerUIController,
      getProxyUrl: () => this.proxyUrl,
      getSessionId: () => this.playbackSessionId,
      getSourceType: () => this.sourceType,
      getStreamLoader: () => this.streamTransport?.current ?? null,
      getStreamType: () => this.currentStreamType,
      getStreamUrl: () => this.streamUrl,
      getSubtitleOffsetMs: () => this.subtitleOffsetMs,
      getTransitionController: () => this.playbackEngineTransitionController,
      getVideo: () => this.video,
      handlePlaybackEnded: () => this.handlePlaybackEnded(),
      handlePlaybackPaused: () => this.handlePlaybackPaused(),
      handlePlaybackStarted: () => this.handlePlaybackStarted(),
      hasProbedAudioTrack: (trackIndex) =>
        this.trackProbeController?.hasProbedAudioTrack(trackIndex) === true,
      initPlayer: (options) => this.initPlayer(options),
      isAVPlayerAttempted: () => this.avPlayerAttempted === true,
      isDestroyed: () => this._destroyed === true,
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      isSwitchingToAVPlayer: () => this._switchingToAVPlayer === true,
      isUsingAVPlayer: () => this.usingAVPlayer === true,
      lifecycleLogsEnabled: () => this.playerLifecycleLogs === true,
      loadExternalSubtitle: (sessionId) => this.loadExternalSubtitleIfAvailable(sessionId),
      loadNativeExternalSubtitle: (sessionId) =>
        this.loadNativeExternalSubtitleIfAvailable(sessionId),
      markAVPlayerAttempted: () => {
        this.avPlayerAttempted = true;
      },
      markAvbridgeAttempted: () => {
        this.avbridgeAttempted = true;
      },
      markH265webAttempted: () => {
        this.h265webAttempted = true;
      },
      markMpegtsRecovered: () => this.mpegtsRecoveryCoordinator?.markRecovered(),
      markPlaying: () => this.playbackMetrics?.markPlaying(),
      playNativeAfterResume: (sessionId) => this.playNativeAfterResume(sessionId),
      probeMetadataInBackground: () => this.probeMetadataInBackground(),
      recordFallbackAttempt: () => {
        this.fallbackAttempts++;
        this.lastFallbackTime = Date.now();
      },
      recordPlaybackError: () => this.playbackMetrics?.recordError(),
      recoverFromMpegtsError: (data) => this.recoverFromMpegtsError(data),
      registerMediaElementEngine: (engineId, engine, options) =>
        this.setMediaElementEngine(engineId, engine, options),
      releaseEngine: (engineId) => this.playbackOrchestrator?.releaseEngine(engineId),
      reportDebug: (stage, extra) => this.reportPlayerDebug(stage, extra),
      reportLifecycle: (stage, extra) => this.reportPlayerLifecycle(stage, extra),
      reportProgress: () => this.reportProgress(),
      resetNativeMediaElement: () => this.resetNativeMediaElement(),
      resetNativeSubtitles: () => {
        this.nativeSubtitleController?.reset();
        this.subtitleTracks = [];
      },
      savePlaybackPosition: (time) => {
        this._savedPosition = { time };
      },
      setAVPlayer: (engine) => {
        this.avPlayer = engine;
      },
      setAvbridge: (engine) => {
        this.avbridge = engine;
      },
      setH265web: (engine) => {
        this.h265web = engine;
      },
      setAudioTrack: (trackIndex) => this.setAudioTrack(trackIndex),
      setNativeBufferManager: (manager) => {
        this.nativeBufferManager = manager;
      },
      setNativePlaybackEventsSuppressed: (suppressed) => {
        this._suppressNativePlaybackEvents = suppressed === true;
      },
      setNativeTouchControls: (enabled) => this.setNativeTouchControls(enabled),
      setPlaybackSystemState: (state) => this.setPlaybackSystemState(state),
      setSubtitleDelay: (delayMs) => this.playbackOrchestrator?.setSubtitleDelay(delayMs),
      setSubtitleTrack: (trackIndex) => this.setSubtitleTrack(trackIndex),
      setUsingAVPlayer: (using) => {
        this.usingAVPlayer = using === true;
      },
      setUsingAvbridge: (using) => {
        this.usingAvbridge = using === true;
      },
      setUsingH265web: (using) => {
        this.usingH265web = using === true;
      },
      showPlaybackError: (message, hint = null) => this.showPlaybackError(message, hint),
      syncPiPAvailability: () => this.syncPiPAvailability(),
      takeResumeTime: (fallback) => this.takeResumeTime(fallback),
      teardownAVPlayer: (player) => this.teardownAVPlayer(player),
      teardownStreamLoaderForTransition: (sessionId) =>
        this.teardownStreamLoaderForTransition(sessionId),
      toAbsoluteUrl: (url) => this.toAbsoluteUrl(url),
      trackManagedEngine: (engineId, engine) => this.trackManagedEngine(engineId, engine),
      tryAVPlayerFallback: () => this.tryAVPlayerFallback(),
      updateAudioTracks: () => this.updateAudioTracks(),
      updateMediaSessionPosition: (options) => this.updateMediaSessionPosition(options),
      updateSubtitleTracks: () => this.updateSubtitleTracks(),
      updateTimeUI: () => this.updateTimeUI(),
      updateVolumeUI: () => this.updateVolumeUI(),
    };
  },

  initPlaybackEngineActivation() {
    this.playbackEngineActivation?.destroy();
    const host = this.buildPlaybackEngineActivationHost();
    const mpegtsActivation = createMpegtsEngineActivation({ host });
    this.nativeEngineActivation?.destroy();
    this.nativeEngineActivation = createNativeEngineActivation({ host });
    this.avPlayerEngineActivation?.destroy();
    this.avPlayerEngineActivation = createAvPlayerEngineActivation({ host });
    this.avbridgeEngineActivation = createAvbridgeEngineActivation({ host });
    this.h265webEngineActivation = createH265webEngineActivation({ host });

    this.playbackEngineActivation = createPlaybackEngineActivation({
      host,
      activations: {
        [ENGINE_SELECTION.HLS_JS]: createHlsEngineActivation({ host }),
        [ENGINE_SELECTION.MPEGTS]: mpegtsActivation,
        [ENGINE_SELECTION.MPEGTS_FLV]: mpegtsActivation,
        [ENGINE_SELECTION.NATIVE]: this.nativeEngineActivation,
        [ENGINE_SELECTION.AVPLAYER]: this.avPlayerEngineActivation,
        [ENGINE_SELECTION.AVBRIDGE]: this.avbridgeEngineActivation,
        [ENGINE_SELECTION.H265WEB]: this.h265webEngineActivation,
        [ENGINE_SELECTION.FLV_UNSUPPORTED]: () => {
          this.showPlaybackError(FLV_UNSUPPORTED_MESSAGE);
          return false;
        },
      },
      onUnknownSelection: (selection) =>
        log.warn("[VideoPlayer] Unknown engine decision:", selection),
      onError: (operation, error, request) =>
        log.error(`[VideoPlayer] Engine activation ${operation} failed:`, {
          error,
          selection: request?.selection,
          sessionId: request?.sessionId,
        }),
    });
  },

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

  buildTrackOperationsHost() {
    return {
      getNativeSubtitleController: () => this.nativeSubtitleController,
      getOrchestrator: () => this.playbackOrchestrator,
      getPresentation: () => this.playerTrackPresentationController,
      getSessionId: () => this.playbackSessionId,
      getStreamTransport: () => this.streamTransport,
      getSubtitleSourceResolver: () => this.subtitleSourceResolver,
      getTrackState: () => ({
        imdbId: this.imdbId,
        preferredAudioTrack: this._preferredAudioTrack,
        preferredSubtitleTrack: this._preferredSubtitleTrack,
        selectedSubtitleTrack: this.selectedSubtitleTrack,
        sourceType: this.sourceType,
        subtitleLang: this.subtitleLang,
        subtitleOffsetMs: this.subtitleOffsetMs,
        subtitleTracks: this.subtitleTracks,
        subtitlesEnabled: this.subtitlesEnabled,
      }),
      hasActiveAVPlayer: () => Boolean(this.usingAVPlayer && this.avPlayer),
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      setAudioTrack: (trackIndex) => this.setAudioTrack(trackIndex),
      setSubtitleTrack: (trackIndex) => this.setSubtitleTrack(trackIndex),
      updateSubtitleTracks: () => this.updateSubtitleTracks(),
    };
  },

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
    if (this._terminalPlaybackError) {
      this.setPlaybackSystemState("none");
      return;
    }

    if (this.mediaElementEngine?.id === ENGINE_ID.HLS) {
      this.hlsRecoveryCoordinator?.markRecovered();
    }
    if (this.mediaElementEngine?.id === ENGINE_ID.MPEGTS) {
      this.mpegtsRecoveryCoordinator?.markRecovered();
    }

    this.observePlaybackState(PLAYBACK_STATE.PLAYING, "playback_started");
    this.setPlaybackSystemState("playing");
  },

  handlePlaybackPaused() {
    this.setPlaybackSystemState(this._terminalPlaybackError ? "none" : "paused");
  },

  handlePlaybackEnded() {
    this.setPlaybackSystemState("none");
  },

  setupIosPwaTapControls() {
    if (!this.iosPwaMode) return;

    this.el.classList.add("ios-pwa-tap-playback");
    this._onIosPwaTap = (event) => {
      if (!this.shouldHandleIosPwaTap(event)) return;

      const now = Date.now();
      if (now - this._lastIosPwaTapAt < 350) return;
      this._lastIosPwaTapAt = now;

      if (!this.playerUIController.controlsVisible) {
        this.playerUIController.revealControls();
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

  setupSourceFailover() {
    const statusElement = this.el.querySelector("#source-failover-status");

    this.sourceFailoverController = createSourceFailoverController({
      enabled: this.sourceFailoverEnabled,
      statusElement,
      pushRequest: (payload) => this.pushEventSafe("request_source_failover", payload),
      onApply: (payload) => this.applySourceFailover(payload),
      onUnavailable: (terminalError, payload) => {
        this.presentTerminalPlaybackError(
          terminalError?.message || payload?.error_message || "Falha na reprodução",
          payload?.hint || null,
        );
      },
    });

    const applyRef = this.handleEvent("source_failover", (payload) =>
      this.sourceFailoverController?.apply(payload),
    );
    const unavailableRef = this.handleEvent("source_failover_unavailable", (payload) =>
      this.sourceFailoverController?.unavailable(payload),
    );

    this.lifecycle.add(() => {
      this.removeHandleEvent?.(applyRef);
      this.removeHandleEvent?.(unavailableRef);
      this.sourceFailoverController?.destroy();
      this.sourceFailoverController = null;
    });
  },

  applySourceFailover(payload) {
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
    this.contentId = String(payload.content_id);
    this.useProxy = true;
    this.currentUrl = null;
    this.currentStreamType = payload.stream_type || null;

    this.el.dataset.streamUrl = this.streamUrl;
    this.el.dataset.proxyUrl = this.proxyUrl;
    this.el.dataset.sourceType = this.sourceType;
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

  setupEventListeners() {
    this.mediaEventBindings = createMediaEventBindings({
      host: this.buildMediaEventBindingsHost(),
      lifecycle: this.lifecycle,
      root: this.el,
      video: this.video,
    });
    this.mediaEventBindings.bindControlEvents();
    this.playerUIController.bindRetry(
      () => this.retryPlaybackFromError(),
      (target, event, handler) => this.lifecycle.listen(target, event, handler),
    );
    this.setupIosPwaTapControls();
    this.setupMobileControls();
    this.mediaEventBindings.bindMediaEvents();
    this.mediaEventBindings.bindPageLifecycle();
    this.bindLiveViewCommands();
  },

  buildMediaEventBindingsHost() {
    return {
      emergencyStopPlayback: () => this.emergencyStopPlayback(),
      emitPlaybackEvent: (name) => emitPlaybackEvent(this.el, name),
      flushPlaybackMetrics: (outcome) => this.flushPlaybackMetrics(outcome),
      getBufferingController: () => this.nativeBufferingController,
      getIosPwaController: () => this.iosPwaPlaybackController,
      getUiController: () => this.playerUIController,
      getWatchPartyPolicy: () => this.watchPartyPolicy,
      handleNativeVolumeChange: () => this.handleNativeVolumeChange(),
      handlePlaybackEnded: () => this.handlePlaybackEnded(),
      handlePlaybackPaused: () => this.handlePlaybackPaused(),
      handlePlaybackStarted: () => this.handlePlaybackStarted(),
      isIosPwaMode: () => Boolean(this.iosPwaMode),
      isVodContent: () => this.contentType === "vod",
      observePlaybackState: (state, reason) => this.observePlaybackState(state, reason),
      reportDuration: (duration) => this.pushEventSafe("duration_available", { duration }),
      reportProgress: () => this.reportProgress(),
      setPlaybackRate: (rate) => this.setPlaybackRate(rate),
      setVolume: (volume) => this.setVolume(volume),
      setWatchPartySyncHold: (held) => this.setWatchPartySyncHold(held),
      toggleAVPlayerPreference: () => this.toggleAVPlayerPreference(),
      toggleFullscreen: () => this.toggleFullscreen(),
      toggleMute: () => this.toggleMute(),
      togglePiP: () => this.togglePiP(),
      togglePlayPause: () => this.togglePlayPause(),
      updateBufferBar: () => this.updateBufferBar(),
      updateTimeUI: () => this.updateTimeUI(),
      usesNativePlaybackEvents: () => this.usesNativePlaybackEvents(),
    };
  },

  setupMobileControls() {
    this.mobileControls = createMobileControls({
      root: this.el,
      controls: this.el.querySelector("#player-controls"),
      video: this.video,
      presentation: this.playerUIController,
      shouldUseNativeControls: () => this.nativeTouchControls || this.iosPwaMode,
      toggleFullscreen: () => this.toggleFullscreen(),
    });
  },

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

  showPlaybackError(message, hint = null) {
    const failoverRequested = this.sourceFailoverController?.request({
      contentId: this.contentId,
      position: this.getCurrentTime(),
      reason: message,
    });

    if (failoverRequested) {
      this._terminalPlaybackError = false;
      this.setPlaybackSystemState("none");
      this.playerUIController?.showRecovery();
      this.cleanup();
      return;
    }

    this.presentTerminalPlaybackError(message, hint);
  },

  presentTerminalPlaybackError(message, hint = null) {
    this._terminalPlaybackError = true;
    this.observePlaybackState(PLAYBACK_STATE.TERMINAL, "terminal_error");
    this.setPlaybackSystemState("none");
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
      if (extra.fallback) {
        this.playbackMetrics?.recordFallback(extra.engine);
        this.playbackOrchestrator?.recordFallback(extra.engine);
      } else {
        this.playbackMetrics?.selectEngine(extra.engine);
      }
    } else if (stage === "player_engine_fallback") {
      this.playbackMetrics?.recordFallback(extra.to);
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

  flushPlaybackMetrics(outcome) {
    const metric = this.playbackMetrics?.finish(outcome);
    if (metric) this.pushEventSafe("client_telemetry", metric);
  },

  retryPlaybackFromError() {
    log.info("[VideoPlayer] Retrying playback from error screen");
    this.sourceFailoverController?.reset();
    this.pushEventSafe("reset_source_failover", {});
    this.reportPlayerLifecycle("player_retry_from_error", {
      retry_count: this.retryCount,
      fallback_attempts: this.fallbackAttempts,
    });

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

  teardownAVPlayer(player = this.avPlayer) {
    return this.avPlayerTeardownQueue?.destroy(player) || Promise.resolve();
  },

  cleanup({ preservePlaybackState = false } = {}) {
    this.reportPlayerLifecycle("player_cleanup", {
      preserve_playback_state: preservePlaybackState,
    });

    if (!preservePlaybackState) {
      this.observePlaybackState(PLAYBACK_STATE.DESTROYED, "cleanup");
    }

    this.setPlaybackSystemState("none");
    this.playbackSessionId += 1;
    void this.playbackEngineTransitionController?.cancel("cleanup");
    this.nativeEngineActivation?.cancelBackgroundWork();
    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = null;
    this.hlsRecoveryCoordinator?.cancel();
    this.mpegtsRecoveryCoordinator?.cancel();

    if (this.mediaElementEngine) {
      const mediaElementEngine = this.mediaElementEngine;
      this.mediaElementEngine = null;

      if (this.playbackOrchestrator) {
        this.playbackOrchestrator.releaseEngine(mediaElementEngine.id);
      } else {
        mediaElementEngine
          .destroy()
          .catch((error) =>
            log.debug("[VideoPlayer] Media element engine teardown failed:", error),
          );
      }
    }

    void this.streamTransport?.teardown();

    this.nativeBufferManager?.destroy();
    this.nativeBufferManager = null;

    this.stopAVPlayerTimeUpdates();
    if (this.avPlayer) {
      const avPlayer = this.avPlayer;
      this.avPlayer = null;
      this.teardownAVPlayer(avPlayer);
    }
    this.nativeSubtitleController?.reset();
    this.releaseExternalSubtitleSourceLease();
    this.subtitleSourceResolver?.reset();
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

    const avContainer = this.el?.querySelector("#avplayer-mount");
    if (avContainer) {
      avContainer.replaceChildren();
      avContainer.classList.add("hidden");
    }

    this.usingAVPlayer = false;
    this.setNativeTouchControls(false);

    if (this.video) {
      this.applyAudioState();
      this.resetNativeMediaElement({ restoreAudioState: true });
    }
  },

  resetNativeMediaElement({ restoreAudioState = false } = {}) {
    if (!this.video) return;

    this._suppressNativePlaybackEvents = true;
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
    this._suppressNativePlaybackEvents = true;
    this.setPlaybackSystemState("none");

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

  getPlaybackStateSnapshot() {
    return this.playbackOrchestrator?.snapshot().lifecycle ?? null;
  },

  observePlaybackState(nextState, reason, metadata = {}) {
    return this.playbackOrchestrator?.observe(nextState, reason, metadata) ?? null;
  },

  beginPlaybackSession() {
    if (!this.playbackOrchestrator || this.playbackOrchestrator.destroyed) {
      this.playbackOrchestrator = createPlaybackOrchestrator({
        reportLifecycle: (event, metadata) => this.reportPlayerLifecycle(event, metadata),
        logInvalid: (transition) =>
          log.debug("[VideoPlayer] Invalid playback state transition:", transition),
      });
    }

    this.playbackSessionId = this.playbackOrchestrator.begin();
    return this.playbackSessionId;
  },
  isCurrentPlaybackSession(sessionId) {
    return !this._destroyed && sessionId === this.playbackSessionId;
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

  buildStreamTransportHost() {
    return {
      adoptHlsEngine: (sessionId) => this.activateHlsEngineFromLoader(sessionId),
      getCodecAbr: () => this.codecABR,
      getContentType: () => this.contentType,
      getCurrentUrl: () => this.currentUrl,
      getNetworkMonitor: () => this.networkMonitor,
      getPresentation: () => this.playerUIController,
      getSessionId: () => this.playbackSessionId,
      getStreamingMode: () => this.streamingMode,
      getVideo: () => this.video,
      handleStreamError: (type, data) => this.handleStreamError(type, data),
      isManualQuality: () => this.manualQuality !== null,
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      playNativeAfterResume: (sessionId) => this.playNativeAfterResume(sessionId),
      pushEvent: (event, payload) => this.pushEventSafe(event, payload),
      showQualityChange: (label) => this.playerUI?.showQualityChange(label),
      updateAudioTracks: () => this.updateAudioTracks(),
      updateQualityList: () => this.updateQualityList(),
      updateSubtitleTracks: () => this.updateSubtitleTracks(),
    };
  },

  initPlayer({ sessionId: providedSessionId = null } = {}) {
    this._terminalPlaybackError = false;

    if (!this.streamUrl) {
      this.showPlaybackError("URL do stream nao fornecida");
      return;
    }

    this.playerUIController.showLoading();
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
    const sessionId = providedSessionId ?? this.beginPlaybackSession();
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);
    this.observePlaybackState(PLAYBACK_STATE.LOADING, "source_loading", {
      session_id: sessionId,
      stream_type: this.currentStreamType,
    });
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
    const engine = assertEngineSelection(selectEngine(engineContext));
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

    log.debug("[VideoPlayer] Activating engine (engine_selector decision):", engine);
    void this.playbackEngineActivation.activate(engine, { sessionId });
  },

  buildEngineRecoveryHost() {
    return {
      canRetry: () => this.retryCount < this.maxRetries,
      canTryAVPlayer: () =>
        this.shouldPreferAVPlayerForLiveTs() && !this.usingAVPlayer && !this.avPlayerAttempted,
      cleanup: (options) => this.cleanup(options),
      consumeRetry: () => {
        this.retryCount++;
      },
      getErrorContext: () => ({
        contentId: this.contentId,
        contentType: this.contentType,
        currentUrl: this.currentUrl,
        fallbackAttempts: this.fallbackAttempts,
        retryCount: this.retryCount,
        sourceType: this.sourceType,
        streamType: this.currentStreamType,
        streamingMode: this.streamingMode,
        usingAVPlayer: this.usingAVPlayer,
        video: this.video,
      }),
      getHlsRecoveryContext: () => this.hlsRecoveryContext(),
      getHlsRecoveryCoordinator: () => this.hlsRecoveryCoordinator,
      getMpegtsRecoveryCoordinator: () => this.mpegtsRecoveryCoordinator,
      getPageProtocol: () => window.location.protocol,
      getSessionId: () => this.playbackSessionId,
      getStreamUrls: () => ({
        currentUrl: this.currentUrl,
        streamUrl: this.streamUrl,
        useProxy: this.useProxy,
      }),
      isSessionCurrent: (sessionId) => this.isCurrentPlaybackSession(sessionId),
      observePlaybackState: (state, reason) => this.observePlaybackState(state, reason),
      playNative: () => this.playNative(),
      playWithMpegts: () => this.playWithMpegts(),
      pushEvent: (event, payload) => this.pushEventSafe(event, payload),
      recordError: () => this.playbackMetrics?.recordError(),
      showErrorWithDiagnostics: (message, error, runDiagnostics) =>
        this.showErrorWithDiagnostics(message, error, runDiagnostics),
      showPlaybackError: (message) => this.showPlaybackError(message),
      teardownStreamLoaderForTransition: (sessionId) =>
        this.teardownStreamLoaderForTransition(sessionId),
      tryAVPlayerFallback: () => this.tryAVPlayerFallback(),
      useDirectStream: () => {
        this.useProxy = false;
        this.currentUrl = this.streamUrl;
      },
    };
  },

  handleStreamError(type, data) {
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

  tryAVPlayerFallback() {
    return this.avPlayerEngineActivation?.tryFallback() ?? Promise.resolve(false);
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
    this.playbackCommandController?.destroy();
    this.playbackCommandController = null;
    this._disposePlaybackBridge?.();
    this._disposePlaybackBridge = null;
    this.lifecycle?.dispose();
    this.lifecycle = null;
    this._startupDiagnosticsCancel?.();
    this._startupDiagnosticsCancel = null;
    this.nativeEngineActivation?.cancelBackgroundWork();
    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = null;
    this.playbackEngineTransitionController?.destroy();
    this.cleanup();
    this.playbackBrowserIntegration?.destroy();
    this.playbackBrowserIntegration = null;
    this.playbackEngineActivation?.destroy();
    this.playbackEngineActivation = null;
    this.nativeEngineActivation = null;
    this.avPlayerEngineActivation = null;
    this.avbridgeEngineActivation = null;
    this.h265webEngineActivation = null;
    this.watchPartyPolicy = null;
    this.streamTransport = null;
    this.playbackEngineTransitionController = null;
    this.nativeSubtitleController?.destroy();
    this.nativeSubtitleController = null;
    this.playbackOrchestrator?.destroy();
    this.playbackOrchestrator = null;
    this.networkMonitor?.stop();
    this.nativeBufferManager?.stop();
    this.subtitleSourceResolver?.destroy();
    this.subtitleSourceResolver = null;
    this.trackProbeController?.destroy();
    this.trackProbeController = null;
    this.playerTrackController?.destroy();
    this.trackOperations?.destroy();
    this.trackOperations = null;
    this.playerTrackPresentationController?.destroy();
    this.playerTrackPresentationController = null;
    this.playerUIController?.destroy();
    this.playerUIController = null;
    this.playerUI = null;
    this.stopAVPlayerTimeUpdates();
    this.aspectRatioController?.destroy();
    this.aspectRatioController = null;
    this.mobileControls?.destroy();
    this.mobileControls = null;

    this.mediaEventBindings = null;
    this.engineRecoveryPolicy = null;
    this._onIosPwaTap = null;

    this.nextEpisodeController?.destroy();
    this.nextEpisodeController = null;
    this.nativeBufferingController?.destroy();
    this.nativeBufferingController = null;

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
