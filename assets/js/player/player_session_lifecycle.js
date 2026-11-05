import { playerLogger as log } from "../core/logger.js";
import { getCapabilitySummary } from "../media/codec_detector.js";
import { resolveStreamType } from "../media/stream_loader.js";
import { isWebCodecsSupported } from "../media/webcodecs_decoder.js";
import { isMSEInWorkersSupported } from "../media/worker_mse.js";
import { currentDeviceClass } from "../telemetry/client_telemetry.js";
import { assertEngineSelection, engineIdFromRuntime, PLAYBACK_STATE } from "./engine_contract.js";
import { selectEngineDecision } from "./engine_selector.js";
import { isStandalonePwa } from "./playback_environment.js";
import { createPlaybackOrchestrator } from "./playback_orchestrator.js";
import { getRecommendedPlayer, playerRecommendationKey } from "./player_preferences.js";

/** Session ownership, engine teardown and hook disposal. Called with the hook as receiver. */
export const playerSessionLifecycle = {
  teardownAVPlayer(player = this.avPlayer) {
    return this.avPlayerTeardownQueue?.destroy(player) || Promise.resolve();
  },
  beginMemorySeek() {
    this.providerEngineMemory?.interrupt();
    this._memorySeekTokens ||= new Set();
    const token = Symbol("seek");
    this._memorySeekTokens.add(token);
    return () => {
      if (!this._memorySeekTokens?.delete(token) || this._destroyed) return;
      if (this._memorySeekTokens.size === 0) {
        this.providerEngineMemory?.interrupt();
        this.startupPresentation?.attach({
          native: !["avplayer", "h265web"].includes(engineIdFromRuntime(this)),
        });
      }
    };
  },
  cleanup({ preservePlaybackState = false } = {}) {
    this._memorySeekTokens?.clear();
    this.providerEngineMemory?.clear();
    this.startupPresentation?.cancelFrame();
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
  recoverStartupDeadline() {
    if (this._selectedEngine !== "avplayer") return false;
    this.providerEngineMemory?.clear();
    // ProviderEngineMemory persists in Device Codec Memory; invalidate both active and stored evidence.
    this.avPlayerEngineActivation?.forgetFailedRecommendation();
    if (this.contentType !== "vod" || this.currentStreamType !== "mp4") return false;
    this.avPlayerAttempted = true; // no native -> AVPlayer loop in this attempt
    this.fallbackAttempts++;
    this.lastFallbackTime = Date.now();
    // Do not queue native recovery (or a later manual retry) behind a hung WASM promise.
    this.cleanup();
    this.initPlaybackEngineTransitionController();
    this.initPlayer({ forcedEngine: "native", fallback: true });
    return true;
  },
  initPlayer({ sessionId: providedSessionId = null, forcedEngine = null, fallback = false } = {}) {
    if (this.recoveryGuard?.terminal) return;
    if (this.playbackMetrics?.active && this.recoveryGuard && !this.recoveryGuard.attempt()) return;
    this._terminalPlaybackError = false;

    if (!this.streamUrl) {
      this.showPlaybackError("URL do stream nao fornecida");
      return;
    }

    this.playerUIController.showLoading();
    log.info("Initializing player");
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

    // Use explicit stream type hint from backend if available (token-based URLs have
    // no extension), except that a URL naming HLS (`.m3u8`) always gets an HLS engine.
    this.currentStreamType = resolveStreamType(this.el.dataset.streamType, this.streamUrl);
    log.debug("Detected stream type:", this.currentStreamType);

    this.cleanup();

    // cleanup() advances playbackSessionId to invalidate work still in flight
    // from the engine it just tore down. A caller that hands us a session is
    // continuing that same session (the AVPlayer to native fallback does), so
    // re-adopt it here: otherwise every isSessionCurrent() check below compares
    // against the bumped id, aborts, and no engine is ever activated. The old
    // engine is stopped by cleanup()'s explicit cancellations, not by the id.
    let sessionId;

    if (providedSessionId == null) {
      sessionId = this.beginPlaybackSession();
    } else {
      sessionId = providedSessionId;
      this.playbackSessionId = providedSessionId;
    }
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);
    this.observePlaybackState(PLAYBACK_STATE.LOADING, "source_loading", {
      session_id: sessionId,
      stream_type: this.currentStreamType,
    });
    if (!this.playbackMetrics.active)
      this.playbackMetrics.begin({
        startedAt: this._playbackMountedAt ?? performance.now(),
        contentType: this.contentType,
        streamType: this.currentStreamType,
        displayMode: isStandalonePwa() ? "standalone" : "browser",
        deviceClass: currentDeviceClass(),
        clientRevision: this.clientRevision,
      });
    this.playbackMetrics.markStage("url");
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
    const contentKey = playerRecommendationKey({
      providerId: this.providerId,
      streamType: this.currentStreamType,
    });
    const recommendedPlayer = getRecommendedPlayer(contentKey);
    const engineContext = this.buildEngineContext(recommendedPlayer);
    const decision = selectEngineDecision(engineContext);
    const engine = assertEngineSelection(forcedEngine || decision.engine);
    const reason = fallback ? "failover" : this._pendingEngineReason || decision.reason;
    this._pendingEngineReason = null;
    this._selectedEngine = engine;
    if (!fallback) this.playbackMetrics.selectEngine(engine, reason);

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
    void this.playbackEngineActivation.activate(engine, { sessionId, reason, fallback });
  },
  destroyed() {
    this.providerEngineMemory?.clear();
    this.recoveryGuard?.destroy();
    this.startupPresentation?.destroy();
    this.flushPlaybackMetrics("cancelled", undefined, { beacon: true });
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
    this.playerInteractions?.destroy();
    this.playerInteractions = null;

    this.mediaEventBindings = null;
    this.engineRecoveryPolicy = null;

    this.nextEpisodeController?.destroy();
    this.nextEpisodeController = null;
    this.nativeBufferingController?.destroy();
    this.nativeBufferingController = null;

    if (this.watchInterval) {
      clearInterval(this.watchInterval);
    }

    if (this.el) {
      this.el.__videoPlayerHook = null;
    }
  },
};
