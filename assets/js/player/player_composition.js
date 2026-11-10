import { playerLogger as log } from "../core/logger.js";
import { NetworkMonitor } from "../media/network_monitor.js";
import { isHlsJsSupported, isMpegtsSupported } from "../media/player_libs.js";
import { ContentType, selectStreamingMode } from "../media/streaming_config.js";
import { createWatchPartyPlayerPolicy } from "../watch_party/player_policy.js";
import { createAudioController } from "./audio_controller.js";
import { audioOutputVolume } from "./audio_state.js";
import { createAvbridgeEngineActivation } from "./avbridge_engine_activation.js";
import { createAvPlayerEngineActivation } from "./avplayer_engine_activation.js";
import { ENGINE_SELECTION, PLAYBACK_STATE } from "./engine_contract.js";
import { createEngineRecoveryPolicy } from "./engine_recovery_policy.js";
import { createErrorReport, detectErrorPatterns, formatErrorForLog } from "./error_telemetry.js";
import { createH265webEngineActivation } from "./h265web_engine_activation.js";
import { createHlsEngineActivation } from "./hls_engine_activation.js";
import { createHlsRecoveryCoordinator } from "./hls_recovery_coordinator.js";
import { createIosPwaPlaybackController } from "./ios_pwa_playback_controller.js";
import { LifecycleScope } from "./lifecycle_scope.js";
import { createMediaEventBindings } from "./media_event_bindings.js";
import { createMobileControls } from "./mobile_controls.js";
import {
  createMpegtsEngineActivation,
  FLV_UNSUPPORTED_MESSAGE,
} from "./mpegts_engine_activation.js";
import { createMpegtsRecoveryCoordinator } from "./mpegts_recovery_coordinator.js";
import { NativeBufferingController } from "./native_buffering_controller.js";
import { createNativeEngineActivation } from "./native_engine_activation.js";
import { createNativeSubtitleController } from "./native_subtitle_controller.js";
import { NextEpisodeController } from "./next_episode_controller.js";
import { emitPlaybackEvent } from "./playback_bridge.js";
import { createPlaybackBrowserIntegration } from "./playback_browser_integration.js";
import { createPlaybackCommandController } from "./playback_command_controller.js";
import { createPlaybackEngineActivation } from "./playback_engine_activation.js";
import { PlaybackEngineTeardownQueue } from "./playback_engine_lifecycle.js";
import { createPlaybackEngineTransitionController } from "./playback_engine_transition_controller.js";
import { createPlayerDiagnosticsController } from "./player_diagnostics_controller.js";
import { createPlayerInteractions } from "./player_interactions.js";
import {
  getPlaybackPosition,
  getPreferences,
  saveAudioTrack,
  saveMuted,
  savePlaybackPosition,
  saveSubtitleTrack,
  saveVolume,
} from "./player_preferences.js";
import { createInitialPlayerState } from "./player_state.js";
import { createPlayerTrackController } from "./player_track_controller.js";
import { createPlayerTrackPresentationController } from "./player_track_presentation_controller.js";
import { PlayerUI } from "./player_ui.js";
import { createPlayerUiController } from "./player_ui_controller.js";
import { createSourceFailoverController } from "./source_failover_controller.js";
import { createStreamTransport } from "./stream_transport.js";
import { createSubtitleSourceResolver } from "./subtitle_source_resolver.js";
import { createTrackOperations } from "./track_operations.js";
import { createTrackProbeController } from "./track_probe_controller.js";

/** Collaborator construction and narrow host adapters for the LiveView hook. */
export const playerComposition = {
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
      showPlaybackError: (message, hint, reason) => this.showPlaybackError(message, hint, reason),
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
    this.initPlaybackEngineTransitionController();

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
    this._lastActiveSubtitleTrack =
      Number.isInteger(prefs.subtitleTrack) && prefs.subtitleTrack >= 0
        ? prefs.subtitleTrack
        : null;

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
      onStartupStage: (stage) => this.startupPresentation?.preparing(stage),
      onAutoplayBlocked: () => this.recoveryGuard?.suspend(),
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
        if (snapshot.selectedSubtitleTrack >= 0) {
          this._lastActiveSubtitleTrack = snapshot.selectedSubtitleTrack;
        }
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
  initPlaybackCommandController() {
    this.playbackCommandController?.destroy();
    this.playbackCommandController = createPlaybackCommandController({
      onSeekStart: () => this.beginMemorySeek(),
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
      nextEpisode: () => this.nextEpisodeController?.play(),
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
  initPlaybackEngineTransitionController() {
    this.playbackEngineTransitionController?.destroy();
    const controller = createPlaybackEngineTransitionController({
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
        if (this.playbackEngineTransitionController === controller) {
          this._switchingToAVPlayer = snapshot.active && snapshot.phase !== "cancelled";
        }
      },
    });
    this.playbackEngineTransitionController = controller;
    this._switchingToAVPlayer = false;
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
    const autoplayPlayBtn = this.el.querySelector("#autoplay-play-btn");
    if (autoplayPlayBtn) {
      this.lifecycle.listen(autoplayPlayBtn, "click", () => {
        this.playerUIController.hideAutoplayBlocked();
        this.play();
      });
    }
    this.setupMobileControls();
    this.mediaEventBindings.bindMediaEvents();
    this.mediaEventBindings.bindPageLifecycle();
    this.bindLiveViewCommands();
  },
  setupMobileControls() {
    this.playerInteractions?.destroy();
    this.mobileControls?.destroy();
    this.playerInteractions = createPlayerInteractions({
      root: this.el,
      video: this.video,
      isPaused: () => this.isPaused(),
      getContentType: () => this.contentType,
      seek: (seconds) => this.seek(seconds),
      togglePlayPause: () => this.togglePlayPause(),
      nextEpisode: () => this.nextEpisodeController?.play(),
    });
    this.mobileControls = createMobileControls({
      root: this.el,
      controls: this.el.querySelector("#player-controls"),
      video: this.video,
      presentation: this.playerUIController,
      shouldUseNativeControls: () => this.nativeTouchControls,
      getContentType: () => this.contentType,
      seek: (seconds) => this.playerInteractions.seekBy(seconds),
      togglePlayPause: () => this.togglePlayPause(),
    });
  },
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
      flushPlaybackMetrics: (...args) => this.flushPlaybackMetrics(...args),
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
      getProviderId: () => this.providerId,
      getStreamLoader: () => this.streamTransport?.current ?? null,
      getStreamType: () => this.currentStreamType,
      getStreamUrl: () => this.streamUrl,
      getSubtitleOffsetMs: () => this.subtitleOffsetMs,
      getTransitionController: () => this.playbackEngineTransitionController,
      beginEngineBootstrap: () => this.recoveryGuard?.bootstrap(),
      awaitEngineFrame: () => this.recoveryGuard?.awaitFrame(),
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
      markMpegtsRecovered: () => {},
      markPlaying: () => {
        this.recoveryGuard?.resume();
        this.playbackMetrics?.markStage("play");
        this.playbackMetrics?.markPlaying();
      },
      playNativeAfterResume: (sessionId) => this.playNativeAfterResume(sessionId),
      probeMetadataInBackground: () => this.probeMetadataInBackground(),
      recordFallbackAttempt: () => {
        this.fallbackAttempts++;
        this.lastFallbackTime = Date.now();
      },
      recordPlaybackError: (code) => {
        this.providerEngineMemory?.interrupt();
        this.playbackMetrics?.recordError(code);
        this.recoveryGuard?.attempt();
      },
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
      showPlaybackError: (message, hint = null, reason) =>
        this.showPlaybackError(message, hint, reason),
      syncPiPAvailability: () => this.syncPiPAvailability(),
      takeResumeTime: (fallback) => this.takeResumeTime(fallback),
      teardownAVPlayer: (player) => this.teardownAVPlayer(player),
      teardownStreamLoaderForTransition: (sessionId) =>
        this.teardownStreamLoaderForTransition(sessionId),
      toAbsoluteUrl: (url) => this.toAbsoluteUrl(url),
      trackManagedEngine: (engineId, engine) => this.trackManagedEngine(engineId, engine),
      tryAVPlayerFallback: (reason) => this.tryAVPlayerFallback(reason),
      updateAudioTracks: () => this.updateAudioTracks(),
      updateMediaSessionPosition: (options) => this.updateMediaSessionPosition(options),
      updateSubtitleTracks: () => this.updateSubtitleTracks(),
      updateTimeUI: () => this.updateTimeUI(),
      updateVolumeUI: () => this.updateVolumeUI(),
    };
  },
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
  buildMediaEventBindingsHost() {
    return {
      emergencyStopPlayback: () => this.emergencyStopPlayback(),
      emitPlaybackEvent: (name) => emitPlaybackEvent(this.el, name),
      flushPlaybackMetrics: (...args) => this.flushPlaybackMetrics(...args),
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
      toggleSubtitles: () => this.toggleSubtitles(),
      updateBufferBar: () => this.updateBufferBar(),
      updateTimeUI: () => this.updateTimeUI(),
      usesNativePlaybackEvents: () => this.usesNativePlaybackEvents(),
    };
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
      getNativeHlsSupport: () => this.getNativeHlsSupport(),
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
      recordError: (code) => this.playbackMetrics?.recordError(code),
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
};
