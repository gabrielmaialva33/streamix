import { KeyboardManager } from "../core/keyboard_manager";
import { playerLogger as log, setErrorReporter } from "../core/logger";
import { getCapabilitySummary, getMediaDecodingInfo } from "../media/codec_detector";
import { CodecAwareABR } from "../media/codec_priority";
import { NativeBufferManager } from "../media/native_buffer";
import { NetworkMonitor } from "../media/network_monitor";
import { isHlsJsSupported, isMpegtsSupported } from "../media/player_libs";
import {
  buildQualityProbeCandidates,
  detectQualityCodec,
  qualityVideoCodec,
} from "../media/quality_probe";
import {
  getFileExtension,
  getStreamType,
  isStreamLoaderCancelledError,
  StreamLoader,
} from "../media/stream_loader";
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
import {
  assertEngineSelection,
  ENGINE_ID,
  engineIdFromRuntime,
  PLAYBACK_STATE,
} from "../player/engine_contract.js";
import { selectEngine } from "../player/engine_selector";
import {
  createErrorReport,
  detectErrorPatterns,
  formatErrorForLog,
} from "../player/error_telemetry";
import { evaluateFallbackAttempt } from "../player/fallback_policy";
import {
  createHlsRecoveryCoordinator,
  HLS_RECOVERY_OPERATION,
  HLS_RECOVERY_OUTCOME,
  HLS_RECOVERY_REASON,
} from "../player/hls_recovery_coordinator.js";
import { createIosPwaPlaybackController } from "../player/ios_pwa_playback_controller.js";
import { LifecycleScope } from "../player/lifecycle_scope";
import { createMediaElementEngine } from "../player/media_element_engine.js";
import { createMediaSessionController } from "../player/media_session_controller";
import { createMobileControls } from "../player/mobile_controls";
import { createMpegtsRecoveryCoordinator } from "../player/mpegts_recovery_coordinator.js";
import { NativeBufferingController } from "../player/native_buffering_controller";
import {
  waitForNativeReady as awaitNativeReady,
  waitForNativeSeek as awaitNativeSeek,
  configureNativePlaybackElement as configureNativeElement,
} from "../player/native_playback_controller";
import { createNativePlaybackEngine } from "../player/native_playback_engine.js";
import { buildNativePlaybackSnapshot } from "../player/native_playback_snapshot";
import { NextEpisodeController } from "../player/next_episode_controller";
import {
  exitPictureInPicture,
  isPictureInPictureSupported,
  togglePictureInPicture,
} from "../player/pip_controller.js";
import { emitPlaybackEvent, installPlaybackBridge } from "../player/playback_bridge";
import { createPlaybackEngineAdapter } from "../player/playback_engine_adapter.js";
import {
  PlaybackEngineTeardownQueue,
  resolvePlaybackResumeTime,
} from "../player/playback_engine_lifecycle";
import {
  canRetryDirectStream,
  getPlaybackResourcePolicy,
  hasWebCodecsHevcSupport,
  isAppleTouchDevice,
  isAppleWebKitBrowser,
  isDirectStreamUrlAllowed,
  isFirefoxBrowser,
  isStandalonePwa,
  scheduleLowPriority,
} from "../player/playback_environment";
import { guardPlaybackLoad } from "../player/playback_load_guard.js";
import { loadAVPlayer, loadAvbridge, loadH265web } from "../player/playback_module_loader";
import { createPlaybackStateObserver } from "../player/playback_state_observer.js";
import { createPlaybackTickThrottle } from "../player/playback_tick_throttle.js";
import { clampSeekTime, relativeSeekTarget } from "../player/playback_time";
import { diagnoseError } from "../player/player_diagnostics";
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
import { createInitialPlayerState } from "../player/player_state";
import { PlayerUI } from "../player/player_ui";
import { createScreenWakeLockController } from "../player/screen_wake_lock_controller";
import { createSourceFailoverController } from "../player/source_failover_controller.js";
import { collectStartupDiagnostics } from "../player/startup_diagnostics";
import {
  findPortugueseTrack,
  formatTrackLabel,
  hasSubtitleInLanguage,
} from "../player/track_metadata";

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
    this.initPlayer();

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
    try {
      const policy = this.getPlaybackResourcePolicy();
      const diagnostics = await collectStartupDiagnostics({ policy });
      this.pushEventSafe("device_diagnostics", diagnostics);

      // Initialize codec-aware ABR if supported
      if (diagnostics.advanced.codecRecommendation) {
        this.initCodecAwareABR(diagnostics.advanced.codecRecommendation);
      }
    } catch (e) {
      log.debug("[VideoPlayer] Startup diagnostics failed (non-critical):", e);
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

    this.video = this.el.querySelector("video");
    this.configureNativePlaybackElement();
    Object.assign(this, createInitialPlayerState(this.el));
    this.hlsRecoveryCoordinator = createHlsRecoveryCoordinator({
      onFailure: (error) => this.reportHlsRecoveryFailure(error),
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
    this.avPlayerTeardownQueue = new PlaybackEngineTeardownQueue({
      onError: (error) => log.debug("[VideoPlayer] AVPlayer teardown failed:", error),
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
      onPlay:
        this.partyMode && this.partyRole === "host"
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
    this.nativeBufferingController = new NativeBufferingController({
      contentType: this.contentType,
      emit: (event, payload) => this.pushEventSafe(event, payload),
      metrics: this.playbackMetrics,
      playerUI: this.playerUI,
      video: this.video,
    });

    // Canvas-backed engines leave the native <video> paused, so UI auto-hide
    // must ask the hook for the active engine's state instead of reading the
    // element directly.
    this.playerUI.setIsPlayingFn(() => !this.isPaused());
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
    if (!this.isPiPSupported()) return;

    try {
      const active = await togglePictureInPicture({
        documentRef: document,
        video: this.video,
      });
      this.setPiPState(active);
    } catch (error) {
      console.error("PiP error:", error);
      this.pushEventSafe("pip_error", { message: error.message });
    }
  },

  isPiPSupported() {
    return isPictureInPictureSupported({
      canvasPlaybackActive: this.isCanvasPlaybackActive(),
      documentRef: document,
      video: this.video,
    });
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

  setMediaElementEngine(engineId, engineOverride = null) {
    const current = this.mediaElementEngine;
    if (
      current?.id === engineId &&
      !current.destroyed &&
      (!engineOverride || current.wraps(engineOverride))
    ) {
      return current;
    }

    const engine =
      engineOverride ??
      (engineId === ENGINE_ID.NATIVE
        ? createNativePlaybackEngine({
            video: this.video,
            beforePause: () => this.nativeBufferManager?.markIntentionalPause(),
            beforeSeek: () => this.nativeBufferingController?.prepareSeek(),
            resetSourceOnDestroy: false,
          })
        : createMediaElementEngine({
            video: this.video,
            beforePause: () => this.nativeBufferManager?.markIntentionalPause(),
            beforeSeek: () => this.nativeBufferingController?.prepareSeek(),
          }));

    const next = createPlaybackEngineAdapter({
      id: engineId,
      engine,
      ownsEngine: engineOverride == null,
    });

    this.mediaElementEngine = next;

    if (current) {
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
    const nextState = !!active;
    const changed = this.pipActive !== nextState;
    this.pipActive = nextState;
    this.playerUI?.updatePiPUI(nextState);
    if (changed) this.pushEventSafe("pip_toggled", { active: nextState });
  },

  syncPiPAvailability() {
    this.playerUI?.setPiPAvailable(this.isPiPSupported());
  },

  disablePiPForCanvasPlayback() {
    this.setPiPState(false);
    this.playerUI?.setPiPAvailable(false);

    void exitPictureInPicture({ documentRef: document, video: this.video }).catch(() => {});
  },

  setupPlaybackSystemIntegration() {
    this.screenWakeLockController = createScreenWakeLockController({
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Screen Wake Lock ${operation} skipped:`, error?.message || error),
    });

    this.mediaSessionController = createMediaSessionController({
      metadata: {
        title: this.mediaTitle,
        artist: this.mediaSubtitle,
        album: "Streamix",
      },
      actions: {
        play: () => {
          if (this.isPaused()) return this.togglePlayPause();
          return undefined;
        },
        pause: () => {
          if (!this.isPaused()) return this.togglePlayPause();
          return undefined;
        },
        seekbackward: (event) => this.seek(-(event.seekOffset || 10)),
        seekforward: (event) => this.seek(event.seekOffset || 10),
        seekto: (event) => {
          if (typeof event.seekTime === "number") this.seekTo(event.seekTime);
        },
      },
      onError: (operation, error) =>
        log.debug(`[VideoPlayer] Media Session ${operation} skipped:`, error?.message || error),
    });

    this.setPlaybackSystemState("none");
  },

  setPlaybackSystemState(state) {
    if (this._destroyed && state !== "none") return;

    this.mediaSessionController?.setPlaybackState(state);
    void this.screenWakeLockController?.setPlaybackActive(state === "playing");

    if (state === "none") return;

    this.updateMediaSessionPosition({ force: true });
  },

  updateMediaSessionPosition({ force = false } = {}) {
    if (!this.mediaSessionController) return;

    if (this.contentType !== "vod") {
      if (force) this.mediaSessionController.clearPosition();
      return;
    }

    this.mediaSessionController.updatePosition({
      duration: this.getDuration(),
      position: this.getCurrentTime(),
      playbackRate: this.getPlaybackRate(),
      force,
    });
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

    this.playerUI.hideError();
    this.playerUI.showLoading();
    this.cleanup();
    this.initPlayer();
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
      if (this._watchPartySyncHold && this.partyMode && this.partyRole === "viewer") {
        queueMicrotask(() => this.setWatchPartySyncHold(true));
        return;
      }

      this.playerUI.updatePlayPauseUI(false);
      this.iosPwaPlaybackController.persist({
        userPaused: false,
        wasPlaying: true,
        reason: "play",
      });
      if (this.usesNativePlaybackEvents()) {
        this.handlePlaybackStarted();
        emitPlaybackEvent(this.el, "play");
      }
    });
    this.lifecycle.listenOptional(this.video, "pause", () => {
      this.playerUI.updatePlayPauseUI(true);
      this.nativeBufferingController.handlePause();
      this.iosPwaPlaybackController.persist({
        userPaused: this.iosPwaPlaybackController.pauseWasUserInitiated(),
        wasPlaying: false,
        reason: "pause",
      });
      if (this.usesNativePlaybackEvents()) {
        this.handlePlaybackPaused();
        emitPlaybackEvent(this.el, "pause");
      }
    });
    this.lifecycle.listenOptional(this.video, "ended", () => {
      if (this.usesNativePlaybackEvents()) this.handlePlaybackEnded();
      this.flushPlaybackMetrics("completed");
    });
    this.lifecycle.listenOptional(this.video, "volumechange", () =>
      this.handleNativeVolumeChange(),
    );
    this.lifecycle.listenOptional(this.video, "timeupdate", () => {
      this.updateTimeUI();
      this.nativeBufferingController.handleTimeUpdate();
    });
    this.lifecycle.listenOptional(this.video, "loadedmetadata", () => this.updateTimeUI());
    this.lifecycle.listenOptional(this.video, "ratechange", () =>
      this.playerUI.updateSpeedUI(this.video.playbackRate),
    );
    this.lifecycle.listenOptional(this.video, "progress", () => {
      this.updateBufferBar();
      this.nativeBufferingController.handleProgress();
    });

    // Fullscreen events. Stash the handler so `destroyed()` can
    // remove it — without that, every LiveView nav stacked one
    // more listener on `document` for the lifetime of the SPA.
    this._onFullscreenChange = () => this.playerUI.updateFullscreenUI(!!document.fullscreenElement);
    this.lifecycle.listen(document, "fullscreenchange", this._onFullscreenChange);
    this.lifecycle.listen(document, "webkitfullscreenchange", this._onFullscreenChange);

    this._onIosVisibilityChange = () => this.iosPwaPlaybackController.handleVisibilityChange();
    this.lifecycle.listen(document, "visibilitychange", this._onIosVisibilityChange);

    this._onPageShow = () => this.iosPwaPlaybackController.resume();
    this.lifecycle.listen(window, "pageshow", this._onPageShow);

    this._onPageTeardown = (event) => {
      this.iosPwaPlaybackController.handlePageHide(event);
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
      this.setPiPState(true);
    });

    this.lifecycle.listenOptional(this.video, "leavepictureinpicture", () => {
      this.setPiPState(false);
    });

    this.lifecycle.listenOptional(this.video, "webkitpresentationmodechanged", () => {
      const active = this.video.webkitPresentationMode === "picture-in-picture";
      this.setPiPState(active);
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

    this.lifecycle.listenOptional(this.video, "seeking", () =>
      this.nativeBufferingController.handleSeeking(),
    );
    this.lifecycle.listenOptional(this.video, "seeked", () => {
      this.nativeBufferingController.handleSeeked();
      if (this.usesNativePlaybackEvents()) emitPlaybackEvent(this.el, "seeked");
    });

    // Buffer health monitoring with debounce to prevent flickering
    this.lifecycle.listenOptional(this.video, "waiting", () => {
      this.observePlaybackState(PLAYBACK_STATE.STALLED, "media_waiting");
      this.nativeBufferingController.handleWaiting();
    });
    this.lifecycle.listenOptional(this.video, "playing", () => {
      this.observePlaybackState(PLAYBACK_STATE.PLAYING, "media_playing");
      this.nativeBufferingController.handlePlaying();
    });

    // Also hide loading on canplaythrough (video exits buffering during playback)
    // The "playing" event doesn't fire when video exits buffering if already playing
    this.lifecycle.listenOptional(this.video, "canplaythrough", () =>
      this.nativeBufferingController.handleCanPlayThrough(),
    );
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
      this.playerUI.hideError();
      this.playerUI.showLoading();
      this.cleanup();
      return;
    }

    this.presentTerminalPlaybackError(message, hint);
  },

  presentTerminalPlaybackError(message, hint = null) {
    this._terminalPlaybackError = true;
    this.observePlaybackState(PLAYBACK_STATE.TERMINAL, "terminal_error");
    this.setPlaybackSystemState("none");
    this.playerUI.showError(message, hint);
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
    const currentTime = this.getCurrentTime();
    const duration = this.getDuration();
    this.playerUI.updateTimeUI(currentTime, duration);
    this.updateMediaSessionPosition();
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
    this.showPlaybackError(message);

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

  supportsPlaybackRateControl() {
    return !this.usingAVPlayer && !this.usingH265web;
  },

  applyPartyControlPolicy() {
    if (!this.partyMode || this.partyRole !== "viewer") return;

    const playButton = this.el.querySelector("#play-pause-btn");
    const progress = this.el.querySelector("#progress-container");
    const speedButton = this.el.querySelector("#speed-btn");

    if (playButton) {
      playButton.disabled = true;
      playButton.setAttribute("aria-label", "Reprodução controlada pelo anfitrião");
      playButton.classList.add("cursor-not-allowed", "opacity-60");
    }

    if (progress) {
      progress.setAttribute("aria-disabled", "true");
      progress.classList.add("pointer-events-none", "cursor-not-allowed", "opacity-70");
    }

    if (speedButton) {
      speedButton.disabled = true;
      speedButton.setAttribute("aria-label", "Velocidade controlada pelo anfitrião");
      speedButton.classList.add("cursor-not-allowed", "opacity-60");
    }
  },

  setWatchPartySyncHold(held) {
    const shouldHold = held === true && this.partyMode && this.partyRole === "viewer";
    this._watchPartySyncHold = shouldHold;
    if (!shouldHold) return true;

    const engine = this.getManagedPlaybackEngine();

    if (engine) {
      try {
        if (engine.isPlaying?.() !== false) {
          void Promise.resolve(engine.pause?.()).catch(() => {});
        }
      } catch (error) {
        log.debug("[VideoPlayer] Managed sync hold could not pause playback:", error);
      }
    } else if (this.video && !this.video.paused) {
      this.nativeBufferManager?.markIntentionalPause();
      this.video.pause();
    }

    this.setPlaybackSystemState("paused");
    return true;
  },

  canControlPartyTransport({ remote = false } = {}) {
    return remote || !this.partyMode || this.partyRole === "host";
  },

  rejectViewerTransportControl({ remote = false } = {}) {
    if (this.canControlPartyTransport({ remote })) return false;

    this.playerUI?.showNotice?.("A reprodução é controlada pelo anfitrião.");
    return true;
  },

  setPlaybackRate(rate, { remote = false } = {}) {
    if (this.rejectViewerTransportControl({ remote })) return false;

    const normalizedRate = Number(rate);
    if (!this.video || !Number.isFinite(normalizedRate) || normalizedRate <= 0) return false;

    if (!this.supportsPlaybackRateControl()) {
      this.playerUI?.updateSpeedUI(1);
      this.updateMediaSessionPosition({ force: true });
      return false;
    }

    // iOS Safari with native HLS flushes the decoder on any playbackRate
    // change ≠ 1.0, producing a 50-100ms stall. When we're already in
    // "conservative sync" mode (i.e. the watch_party_sync hook detected
    // native HLS and is throttling its corrections), cap the user's
    // chosen speed at 1.0 — otherwise the stall stacks on top of every
    // drift correction and the video looks broken.
    const native = !!this.video.canPlayType?.("application/vnd.apple.mpegurl");

    if (native && this.partyMode && normalizedRate > 1.0) {
      this.video.playbackRate = 1.0;
      if (!remote) savePlaybackRate(1.0);
      this.updateMediaSessionPosition({ force: true });
      if (!remote) this.pushEventSafe("playback_rate_changed", { rate: 1.0 });
      this.playerUI?.showNotice?.(
        "Velocidade variável não é suportada com HLS nativo do iOS durante watch party.",
      );
      return true;
    }

    this.video.playbackRate = normalizedRate;
    if (!remote) savePlaybackRate(normalizedRate);
    this.updateMediaSessionPosition({ force: true });
    if (!remote) this.pushEventSafe("playback_rate_changed", { rate: normalizedRate });
    return true;
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
    const allowed = !(this.partyMode && this.partyRole === "viewer");
    enabled = enabled && allowed;
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

    this.playerUI.hideError();
    this.playerUI.showLoading();
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
    this._metadataProbeCancel?.();
    this._metadataProbeCancel = null;
    this._qualityCapabilitiesCancel?.();
    this._qualityCapabilitiesCancel = null;
    this.hlsRecoveryCoordinator?.cancel();
    this.mpegtsRecoveryCoordinator?.cancel();

    if (this.mediaElementEngine) {
      const mediaElementEngine = this.mediaElementEngine;
      this.mediaElementEngine = null;
      mediaElementEngine
        .destroy()
        .catch((error) => log.debug("[VideoPlayer] Media element engine teardown failed:", error));
    }

    if (this.streamLoader) {
      const streamLoader = this.streamLoader;
      this.streamLoader = null;
      try {
        this._streamLoaderTeardownPromise = Promise.resolve(streamLoader.destroy()).catch((error) =>
          log.debug("[VideoPlayer] StreamLoader teardown failed:", error),
        );
      } catch (error) {
        log.debug("[VideoPlayer] StreamLoader teardown failed:", error);
        this._streamLoaderTeardownPromise = Promise.resolve();
      }
    }
    this.hls = null;
    this.mpegtsPlayer = null;

    this.nativeBufferManager?.destroy();
    this.nativeBufferManager = null;

    this.stopAVPlayerTimeUpdates();
    if (this.avPlayer) {
      const avPlayer = this.avPlayer;
      this.avPlayer = null;
      this.teardownAVPlayer(avPlayer);
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
    return this.playbackStateObserver?.snapshot() ?? null;
  },

  observePlaybackState(nextState, reason, metadata = {}) {
    return this.playbackStateObserver?.observe(nextState, reason, metadata) ?? null;
  },

  beginPlaybackSession() {
    this.playbackSessionId += 1;
    this.playbackStateObserver = createPlaybackStateObserver({
      reportLifecycle: (event, metadata) => this.reportPlayerLifecycle(event, metadata),
      logInvalid: (transition) =>
        log.debug("[VideoPlayer] Invalid playback state transition:", transition),
    });
    this.playbackStateObserver.begin(this.playbackSessionId);
    return this.playbackSessionId;
  },

  isCurrentPlaybackSession(sessionId) {
    return !this._destroyed && sessionId === this.playbackSessionId;
  },

  hlsRecoveryContext() {
    const loader = this.streamLoader;
    const sessionId = this.playbackSessionId;
    const url = this.currentUrl;

    return {
      isCurrent: () =>
        !!loader &&
        this.isCurrentPlaybackSession(sessionId) &&
        this.streamLoader === loader &&
        this.currentUrl === url,
      loader,
      url,
    };
  },

  reportHlsRecoveryFailure(error) {
    if (isStreamLoaderCancelledError(error)) return;
    log.warn("HLS recovery failed:", error);
    this.showErrorWithDiagnostics(
      "Nao foi possivel recuperar o stream",
      { message: error?.message || String(error), type: "network" },
      true,
    );
  },

  async teardownStreamLoaderForTransition(sessionId) {
    if (!this.isCurrentPlaybackSession(sessionId)) return null;
    this.cleanup({ preservePlaybackState: true });
    const transitionSessionId = this.playbackSessionId;
    await (this._streamLoaderTeardownPromise || Promise.resolve());
    return this.isCurrentPlaybackSession(transitionSessionId) ? transitionSessionId : null;
  },

  configureNativePlaybackElement(options = {}) {
    configureNativeElement(this.video, options);
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

  async playNativeAfterResume(sessionId, resumeTime = this.takeResumeTime()) {
    if (!this.video || !this.isCurrentPlaybackSession(sessionId)) return;

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
      const nativeEngine = this.getNativePlaybackEngine();
      await (nativeEngine ? nativeEngine.play() : this.video.play());
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
        // Keep the standard bottom controls visible so the user can start
        // playback without covering the video with an autoplay overlay.
        this.playerUI.showControls();
        this.playerUI.clearHideControlsTimeout();
      } else {
        this.showPlaybackError(`Falha ao iniciar reproducao: ${e.message}`);
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
    this._terminalPlaybackError = false;

    if (!this.streamUrl) {
      this.showPlaybackError("URL do stream nao fornecida");
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
        this.showPlaybackError("Reproducao FLV nao suportada neste navegador");
        break;
      default:
        log.warn("[VideoPlayer] Unknown engine decision:", engine);
        this.playNative();
    }
  },

  logHlsRecoveryDecision(decision) {
    switch (decision.reason) {
      case HLS_RECOVERY_REASON.MANIFEST_SOFT_RELOAD:
        log.warn(`Soft recovering HLS (attempt ${decision.nextAttempts})...`);
        break;
      case HLS_RECOVERY_REASON.NETWORK_RESTART:
        log.warn(`Network error, restarting HLS load (attempt ${decision.nextAttempts})...`);
        break;
      case HLS_RECOVERY_REASON.NETWORK_SOFT_RELOAD:
        log.warn("Network recovery exhausted, soft reloading HLS...");
        break;
      case HLS_RECOVERY_REASON.MEDIA_RECOVERY:
        log.warn(`Media error, recovering HLS (attempt ${decision.nextAttempts})...`);
        break;
      case HLS_RECOVERY_REASON.MEDIA_SOFT_RELOAD:
        log.warn("Media recovery exhausted, soft reloading HLS...");
        break;
      default:
        log.warn("[VideoPlayer] HLS recovery started:", {
          operation: decision.operation,
          reason: decision.reason,
        });
    }
  },

  handleHlsFallback(decision) {
    if (decision.reason === HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE) {
      if (this.retryCount < this.maxRetries && isMpegtsSupported()) {
        this.retryCount++;
        log.warn("HLS failed, trying mpegts.js...");
        this.observePlaybackState(PLAYBACK_STATE.RECOVERING, "hls_to_mpegts_fallback");
        this.cleanup({ preservePlaybackState: true });
        this.playWithMpegts();
      } else {
        this.showErrorWithDiagnostics(
          "Não foi possível carregar — servidor indisponível",
          { message: "Manifest load failed", type: "network" },
          true,
        );
      }
      return;
    }

    if (this.retryCount < this.maxRetries) {
      this.retryCount++;
      this.observePlaybackState(PLAYBACK_STATE.RECOVERING, "hls_engine_fallback");
      this.cleanup({ preservePlaybackState: true });
      if (isMpegtsSupported()) {
        this.playWithMpegts();
      } else {
        this.playNative();
      }
    } else {
      this.showErrorWithDiagnostics(
        "Erro de reprodução — formato não suportado",
        { message: "Media format error", type: "codec" },
        true,
      );
    }
  },

  handleHlsStreamError(data) {
    const recovery = this.hlsRecoveryCoordinator.handle(data, this.hlsRecoveryContext());
    const { decision } = recovery;

    switch (decision.outcome) {
      case HLS_RECOVERY_OUTCOME.IGNORED:
        log.debug("HLS non-fatal error:", decision.event.details);
        break;
      case HLS_RECOVERY_OUTCOME.REFRESH_TOKEN:
        log.warn("Auth error detected, requesting token refresh");
        this.pushEventSafe("request_token_refresh", {});
        break;
      case HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING:
      case HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED:
        this.logHlsRecoveryDecision(decision);
        break;
      case HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED:
        this.handleHlsFallback(decision);
        break;
      default:
        log.warn("[VideoPlayer] Unknown HLS recovery outcome:", decision);
        this.handleHlsFallback({
          ...decision,
          operation: HLS_RECOVERY_OPERATION.SOFT_RELOAD,
          reason: HLS_RECOVERY_REASON.UNHANDLED_FATAL,
        });
    }

    return recovery;
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
      this.handleHlsStreamError(data);
    } else if (type === "mpegts") {
      void this.recoverFromMpegtsError(data);
    }
  },

  recoverFromMpegtsError(data) {
    const sessionId = this.playbackSessionId;
    let transitionSessionId = sessionId;

    return this.mpegtsRecoveryCoordinator.handle(data, {
      sessionId,
      canTryAVPlayer:
        this.shouldPreferAVPlayerForLiveTs() && !this.usingAVPlayer && !this.avPlayerAttempted,
      canTryDirect: canRetryDirectStream({
        currentUrl: this.currentUrl,
        pageProtocol: window.location.protocol,
        streamUrl: this.streamUrl,
        useProxy: this.useProxy,
      }),
      cleanup: async () => {
        const nextSessionId = await this.teardownStreamLoaderForTransition(sessionId);
        if (nextSessionId == null) return false;
        transitionSessionId = nextSessionId;
        return true;
      },
      isCurrent: () => this.isCurrentPlaybackSession(transitionSessionId),
      refreshToken: () => {
        log.warn("mpegts.js authentication failed; requesting a fresh token");
        this.pushEventSafe("request_token_refresh", {});
      },
      retryDirect: () => {
        if (!isDirectStreamUrlAllowed(this.streamUrl, window.location.protocol)) {
          log.warn("mpegts.js direct retry blocked by mixed-content policy");
          void this.playWithMpegts();
          return;
        }

        log.warn("mpegts.js proxy path failed; retrying the direct URL");
        this.useProxy = false;
        this.currentUrl = this.streamUrl;
        void this.playWithMpegts();
      },
      retryMpegts: (decision) => {
        log.warn(`Recreating mpegts.js after ${decision?.reason ?? "transport error"}`);
        void this.playWithMpegts();
      },
      fallbackAVPlayer: () => {
        log.warn("mpegts.js recovery exhausted; trying AVPlayer");
        void this.tryAVPlayerFallback();
      },
      fallbackNative: () => this.playNative(),
      onFailure: (error) => {
        log.error("mpegts.js recovery failed:", error);
        if (this.isCurrentPlaybackSession(transitionSessionId)) {
          this.showPlaybackError("Erro ao recuperar o stream ao vivo");
        }
      },
    });
  },

  async playWithHls() {
    this._suppressNativePlaybackEvents = false;
    this.syncPiPAvailability();
    log.info("Playing with HLS.js, url:", this.currentUrl);
    this.reportPlayerLifecycle("player_engine_selected", { engine: ENGINE_ID.HLS });

    if (!isHlsJsSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.showPlaybackError("HLS nao suportado neste navegador");
      }
      return;
    }

    const sessionId = this.playbackSessionId;
    const loader = this.ensureStreamLoader();

    const result = await guardPlaybackLoad({
      load: () => loader.loadHls(this.currentUrl),
      isCancelled: isStreamLoaderCancelledError,
      isCurrent: () => this.isCurrentPlaybackSession(sessionId) && this.streamLoader === loader,
      destroy: () => loader.destroy(),
    });
    if (result.status === "cancelled" || result.status === "stale") return;
    if (result.status === "loaded") {
      const hlsEngine = this.streamLoader.getHlsEngine();
      if (!hlsEngine) throw new Error("HLS engine was not registered by StreamLoader");

      this.hls = result.engine;
      this.setMediaElementEngine(ENGINE_ID.HLS, hlsEngine);
      return;
    }

    log.error("HLS.js initialization failed:", result.error);
    this.playbackMetrics?.recordError();
    const transitionSessionId = await this.teardownStreamLoaderForTransition(sessionId);
    if (transitionSessionId == null) return;

    if (this.getNativeHlsSupport()) {
      this.playNative();
    } else {
      this.showPlaybackError("HLS nao suportado neste navegador");
    }
  },

  async playWithAvbridge() {
    this._suppressNativePlaybackEvents = false;
    this.disablePiPForCanvasPlayback();
    log.info("Playing with avbridge, url:", this.currentUrl);
    this.avbridgeAttempted = true;
    this.reportPlayerLifecycle("player_engine_selected", { engine: ENGINE_ID.AVBRIDGE });

    const sessionId = this.playbackSessionId;
    const resumeTime = this.takeResumeTime();

    try {
      const { AvbridgeWrapper } = await loadAvbridge();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      this.avbridge = createPlaybackEngineAdapter({
        id: ENGINE_ID.AVBRIDGE,
        engine: new AvbridgeWrapper({ video: this.video }),
      });
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
      this.handlePlaybackStarted();
      this.playbackMetrics?.markPlaying();
    } catch (err) {
      this.setPlaybackSystemState("none");
      log.warn("[Avbridge] init failed, falling back to AVPlayer:", err);
      this.playbackMetrics?.recordError();
      this.reportPlayerLifecycle("player_engine_fallback", {
        from: ENGINE_ID.AVBRIDGE,
        to: ENGINE_ID.AVPLAYER,
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
    this.disablePiPForCanvasPlayback();
    log.info("Playing with h265web, url:", this.currentUrl);
    this.h265webAttempted = true;
    this.reportPlayerLifecycle("player_engine_selected", { engine: ENGINE_ID.H265WEB });

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

      this.h265web = createPlaybackEngineAdapter({
        id: ENGINE_ID.H265WEB,
        engine: new H265webWrapper({
          video: this.video,
          mountEl,
          // Override base URL via `data-h265web-base-url` on the player
          // container — useful when the SDK is served from a different
          // origin than Phoenix (CDN, edge cache).
          baseUrl: this.el.dataset.h265webBaseUrl || undefined,
        }),
      });
      const h265web = this.h265web;
      const h265webTicks = createPlaybackTickThrottle();
      h265web.on("playing", () => {
        if (!this.isCurrentPlaybackSession(sessionId) || this.h265web !== h265web) return;
        this.playerUI.updatePlayPauseUI(false);
        this.handlePlaybackStarted();
        emitPlaybackEvent(this.el, "play");
      });
      h265web.on("paused", () => {
        if (!this.isCurrentPlaybackSession(sessionId) || this.h265web !== h265web) return;
        this.playerUI.updatePlayPauseUI(true);
        this.handlePlaybackPaused();
        emitPlaybackEvent(this.el, "pause");
      });
      h265web.on("timeupdate", () => {
        if (!this.isCurrentPlaybackSession(sessionId) || this.h265web !== h265web) return;

        const tick = h265webTicks.next();
        if (tick.updateUi) this.updateTimeUI();
        if (tick.reportProgress && this.contentType === "vod") this.reportProgress();
      });
      h265web.on("ended", () => {
        if (!this.isCurrentPlaybackSession(sessionId) || this.h265web !== h265web) return;
        this.playerUI.updatePlayPauseUI(true);
        this.handlePlaybackEnded();
        this.flushPlaybackMetrics("completed");
      });
      await h265web.load(this.currentUrl, {
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
      await h265web.play();
      this.playbackMetrics?.markPlaying();
    } catch (err) {
      this.setPlaybackSystemState("none");
      log.warn("[H265web] init failed, falling back to AVPlayer:", err);
      this.playbackMetrics?.recordError();
      this.reportPlayerLifecycle("player_engine_fallback", {
        from: ENGINE_ID.H265WEB,
        to: ENGINE_ID.AVPLAYER,
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
    this._suppressNativePlaybackEvents = false;
    this.syncPiPAvailability();
    log.info("Playing with mpegts.js, type:", type, "url:", this.currentUrl);
    this.reportPlayerDebug("play_with_mpegts", { requested_type: type });
    const sessionId = this.playbackSessionId;
    this.reportPlayerLifecycle("player_engine_selected", {
      engine: ENGINE_ID.MPEGTS,
      requested_type: type,
      session_id: sessionId,
    });

    const loader = this.ensureStreamLoader();
    const onPlaying = () => {
      if (!this.isCurrentPlaybackSession(sessionId)) return;
      this._mpegtsNetworkAttempts = 0;
      this._mpegtsRecreateAttempts = 0;
      this.playerUI.hideLoading();
      this.playerUI.hideError();
    };
    this.video.addEventListener("playing", onPlaying, { once: true });

    const result = await guardPlaybackLoad({
      load: () => loader.loadMpegts(this.currentUrl, type),
      isCancelled: isStreamLoaderCancelledError,
      isCurrent: () => this.isCurrentPlaybackSession(sessionId) && this.streamLoader === loader,
      destroy: () => loader.destroy(),
    });

    if (result.status === "cancelled" || result.status === "stale") {
      this.video.removeEventListener("playing", onPlaying);
      return;
    }

    if (result.status === "loaded") {
      this.mpegtsPlayer = result.engine;
      this.setMediaElementEngine(ENGINE_ID.MPEGTS);

      void this.playNativeAfterResume(sessionId).catch((error) => {
        if (this.isCurrentPlaybackSession(sessionId)) {
          log.debug("mpegts.js play request failed:", error);
        }
      });

      return;
    }

    this.video.removeEventListener("playing", onPlaying);
    log.error("mpegts.js initialization error:", result.error);
    this.playbackMetrics?.recordError();
    if (type === "flv") {
      const transitionSessionId = await this.teardownStreamLoaderForTransition(sessionId);
      if (transitionSessionId != null) {
        this.showPlaybackError("Reproducao FLV nao suportada neste navegador");
      }
      return;
    }

    await this.recoverFromMpegtsError({
      errorType: "OtherError",
      errorDetail: "OtherError",
      errorInfo: { cause: result.error },
    });
  },

  playNative() {
    this._suppressNativePlaybackEvents = false;
    this.syncPiPAvailability();
    const sessionId = this.playbackSessionId;
    const resumeTime = this.takeResumeTime();
    log.info("Playing with native video element, url:", this.currentUrl);
    this.setNativeTouchControls(isAppleTouchDevice());
    this.configureNativePlaybackElement({ resumeTime });
    const nativeEngine = this.setMediaElementEngine(ENGINE_ID.NATIVE);
    this.reportPlayerLifecycle("player_engine_selected", {
      engine: ENGINE_ID.NATIVE,
      session_id: sessionId,
    });
    nativeEngine.load(this.currentUrl);
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

      if (this.usingAVPlayer || this._switchingToAVPlayer) {
        log.debug("[VideoPlayer] Ignoring stale native video error during AVPlayer playback");
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

      this.showPlaybackError(message);
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

    this.playNativeAfterResume(sessionId, resumeTime).catch((e) => {
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

  transitionFromFailedAVPlayer({ sessionId, avPlayer, error, resumeTime = 0 }) {
    if (this._avPlayerFailureSessionId === sessionId && this._avPlayerFailurePromise) {
      return this._avPlayerFailurePromise;
    }

    if (!this.isCurrentPlaybackSession(sessionId)) return Promise.resolve(false);

    this._avPlayerFailureSessionId = sessionId;
    const transition = (async () => {
      log.error("[VideoPlayer] AVPlayer failed, returning to native playback:", error);
      this.playbackMetrics?.recordError();

      const contentKey = this.sourceType === "gindex" ? "gindex" : this.currentStreamType;
      if (contentKey) forgetRecommendedPlayer(contentKey);
      const failureResumeTime = resolvePlaybackResumeTime(avPlayer, resumeTime);
      if (this.contentType === "vod" && failureResumeTime > 0) {
        this._savedPosition = { time: failureResumeTime };
      }

      const transitionSessionId = await this.revertToNativePlayer(avPlayer);
      if (this._destroyed || !this.isCurrentPlaybackSession(transitionSessionId)) return false;

      this._switchingToAVPlayer = false;
      this.initPlayer();
      return true;
    })();

    this._avPlayerFailurePromise = transition.finally(() => {
      if (this._avPlayerFailureSessionId === sessionId) {
        this._avPlayerFailureSessionId = null;
        this._avPlayerFailurePromise = null;
      }
    });

    return this._avPlayerFailurePromise;
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
      this.showPlaybackError("Formato de audio nao suportado. Tente novamente mais tarde.");
      return;
    }

    if (this.avPlayerAttempted || this.usingAVPlayer) {
      log.debug("[VideoPlayer] AVPlayer fallback already attempted, skipping");
      return;
    }

    this._switchingToAVPlayer = true;
    this.disablePiPForCanvasPlayback();

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

    let avPlayer = null;

    try {
      // cleanup() starts teardown synchronously but remains non-blocking for
      // LiveView navigation. Before creating another AVPlayer, wait for any
      // queued teardown so shared AudioContext resources cannot overlap.
      await this.avPlayerTeardownQueue.drain();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

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
        await this.teardownAVPlayer(oldAvPlayer);
        if (!this.isCurrentPlaybackSession(sessionId)) return;
      }

      avPlayer = new AVPlayerWrapper({
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
          this.handlePlaybackStarted();
          this.playbackMetrics?.markPlaying();
          emitPlaybackEvent(this.el, "play");

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
          this.handlePlaybackPaused();
          emitPlaybackEvent(this.el, "pause");
        },
        onError: (error) => {
          void this.transitionFromFailedAVPlayer({
            sessionId,
            avPlayer,
            error,
            resumeTime,
          });
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
          this.handlePlaybackEnded();
          this.flushPlaybackMetrics("completed");
        },
      });
      avPlayer = createPlaybackEngineAdapter({
        id: ENGINE_ID.AVPLAYER,
        engine: avPlayer,
      });
      this.avPlayer = avPlayer;

      const avPlayerUrl = this.proxyUrl ? this.toAbsoluteUrl(this.proxyUrl) : this.streamUrl;

      const ext = getFileExtension(this.streamUrl, this.sourceType, this.currentStreamType);
      const isLive = this.contentType === "live";
      log.debug("[VideoPlayer] AVPlayer loading via:", avPlayerUrl, "ext:", ext, "isLive:", isLive);

      await avPlayer.load(avPlayerUrl, this.buildAVPlayerLoadOptions(ext, isLive));
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await this.teardownAVPlayer(avPlayer);
        return;
      }

      if (resumeTime > 0) {
        await avPlayer.seek(resumeTime);
        if (!this.isCurrentPlaybackSession(sessionId)) {
          await this.teardownAVPlayer(avPlayer);
          return;
        }
      }

      avPlayer.setVolume(audioOutputVolume(this.canonicalAudioState()));

      this.usingAVPlayer = true;
      log.debug("[VideoPlayer] Calling AVPlayer play(), wasPlaying:", wasPlaying);
      await avPlayer.play();
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await this.teardownAVPlayer(avPlayer);
        return;
      }
      log.debug("[VideoPlayer] AVPlayer play() completed");

      this.updateMediaSessionPosition({ force: true });
      log.debug("[VideoPlayer] Seamless AVPlayer switch complete");

      // Detect available audio/subtitle tracks from AVPlayer
      this.detectAVPlayerTracks(sessionId);
    } catch (error) {
      await this.transitionFromFailedAVPlayer({ sessionId, avPlayer, error, resumeTime });
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
    this.disablePiPForCanvasPlayback();
    this.avPlayerAttempted = true;

    const sessionId = this.beginPlaybackSession();
    this.playerUI.showLoading();
    let avPlayer = null;

    try {
      // Stop native player fully; pause()+src="" can leave decoded audio alive.
      this.resetNativeMediaElement();

      if (this.avPlayer) {
        const oldAvPlayer = this.avPlayer;
        this.avPlayer = null;
        await this.teardownAVPlayer(oldAvPlayer);
        if (!this.isCurrentPlaybackSession(sessionId)) return;
      }

      await this.avPlayerTeardownQueue.drain();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      const { AVPlayerWrapper } = await loadAVPlayer();
      if (!this.isCurrentPlaybackSession(sessionId)) return;

      // Use server-rendered mount (phx-update="ignore").
      const avContainer = this.el.querySelector("#avplayer-mount");
      avContainer.replaceChildren();
      avContainer.classList.remove("hidden");

      avPlayer = new AVPlayerWrapper({
        container: avContainer,
        onReady: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          log.debug("[VideoPlayer] AVPlayer ready for track switch");
        },
        onError: (e) => {
          void this.transitionFromFailedAVPlayer({
            sessionId,
            avPlayer,
            error: e,
            resumeTime: seekTime,
          });
        },
        onPlay: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(false); // false = not paused
          this.playerUI.hideLoading();
          this.startAVPlayerTimeUpdates();
          this.handlePlaybackStarted();
          this.playbackMetrics?.markPlaying();
          emitPlaybackEvent(this.el, "play");
        },
        onPause: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(true); // true = paused
          this.handlePlaybackPaused();
          emitPlaybackEvent(this.el, "pause");
        },
        onTimeUpdate: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.updateTimeUI();
        },
        onEnded: () => {
          if (!this.isCurrentPlaybackSession(sessionId)) return;
          this.playerUI.updatePlayPauseUI(true);
          this.stopAVPlayerTimeUpdates();
          this.handlePlaybackEnded();
          this.flushPlaybackMetrics("completed");
        },
      });
      avPlayer = createPlaybackEngineAdapter({
        id: ENGINE_ID.AVPLAYER,
        engine: avPlayer,
      });
      this.avPlayer = avPlayer;

      await avPlayer.init();
      if (!this.isCurrentPlaybackSession(sessionId)) {
        await this.teardownAVPlayer(avPlayer);
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
        await this.teardownAVPlayer(avPlayer);
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
          await this.teardownAVPlayer(avPlayer);
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
          await this.teardownAVPlayer(avPlayer);
          return;
        }
      } else {
        this.handlePlaybackPaused();
      }

      // Start time updates
      this.startAVPlayerTimeUpdates();

      // Detect tracks from now-active AVPlayer
      this.detectAVPlayerTracks(sessionId);

      this.playerUI.hideLoading();
      log.debug("[VideoPlayer] Switched to AVPlayer with", trackType, "track", trackIndex);
    } catch (error) {
      await this.transitionFromFailedAVPlayer({
        sessionId,
        avPlayer,
        error,
        resumeTime: seekTime,
      });
    } finally {
      this._switchingToAVPlayer = false;
    }
  },

  async revertToNativePlayer(avPlayer = this.avPlayer) {
    log.debug("[VideoPlayer] Reverting to native player");
    this.reportPlayerLifecycle("player_engine_destroyed", { engine: "avplayer" });
    const transitionSessionId = this.beginPlaybackSession();

    this.stopAVPlayerTimeUpdates();

    if (this.avPlayer === avPlayer) {
      this.avPlayer = null;
    }
    await this.teardownAVPlayer(avPlayer);

    const avContainer = this.el.querySelector("#avplayer-mount");
    if (avContainer) {
      avContainer.replaceChildren();
      avContainer.classList.add("hidden");
    }

    this.video.classList.remove("hidden");
    this.usingAVPlayer = false;
    this.applyAudioState();
    this.updateVolumeUI();
    this.syncPiPAvailability();
    return transitionSessionId;
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
        getPlaybackRate: () => this.getPlaybackRate(),
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

  getNativePlaybackEngine() {
    if (this.mediaElementEngine?.id !== ENGINE_ID.NATIVE || this.mediaElementEngine.destroyed) {
      return null;
    }
    return this.mediaElementEngine;
  },

  getManagedPlaybackEngine() {
    if (this.usingAVPlayer && this.avPlayer) return this.avPlayer;
    if (this.usingAvbridge && this.avbridge) return this.avbridge;
    if (this.usingH265web && this.h265web) return this.h265web;
    return this.getNativePlaybackEngine();
  },

  async togglePlayPause({ remote = false } = {}) {
    if (this.rejectViewerTransportControl({ remote })) return false;
    if (remote && this._watchPartySyncHold && this.isPaused()) return false;

    const engine = this.getManagedPlaybackEngine();

    if (engine) {
      const isPlaying = engine.isPlaying();
      log.debug("[VideoPlayer] togglePlayPause: managed engine isPlaying =", isPlaying);

      try {
        if (isPlaying) {
          await engine.pause();
          this.setPlaybackSystemState("paused");
        } else {
          await engine.play();
          this.setPlaybackSystemState("playing");
        }
      } catch (error) {
        log.error("[VideoPlayer] managed engine play/pause failed:", error);
      }
      return;
    }

    if (this.video.paused) {
      try {
        await this.video.play();
        return true;
      } catch (error) {
        if (error.name !== "AbortError") {
          log.debug("[VideoPlayer] togglePlayPause play() failed:", error.message);
        }
        return false;
      }
    }

    this.nativeBufferManager?.markIntentionalPause();
    this.video.pause();
    return true;
  },

  toggleMute() {
    const audioState = this.audioController.toggleMute();
    this.pushEventSafe("mute_toggled", { muted: audioState.muted });
  },

  adjustVolume(delta) {
    const audioState = this.audioController.adjustVolume(delta);
    this.pushEventSafe("volume_changed", { volume: Math.round(audioState.volume * 100) });
  },

  seek(seconds, { remote = false } = {}) {
    if (this.rejectViewerTransportControl({ remote })) return false;
    if (this.contentType === "live") return false;

    const engine = this.getManagedPlaybackEngine();
    if (engine) {
      const target = relativeSeekTarget(engine.getCurrentTime(), seconds, engine.getDuration());
      if (target === null) return;

      Promise.resolve(engine.seek(target))
        .then(() => this.updateMediaSessionPosition({ force: true }))
        .catch((error) => {
          log.debug("[VideoPlayer] managed engine seek skipped:", error.message);
        });
      return;
    }

    if (this.video) {
      const target = relativeSeekTarget(this.video.currentTime, seconds, this.getDuration());
      if (target !== null) this.seekNativeTo(target);
    }
  },

  seekTo(time, { remote = false } = {}) {
    if (this.rejectViewerTransportControl({ remote })) return false;
    if (this.contentType === "live") return remote ? this.seekLiveTo(time) : false;

    const target = clampSeekTime(time, this.getDuration());
    if (target === null) return;

    const engine = this.getManagedPlaybackEngine();
    if (engine) {
      Promise.resolve(engine.seek(target))
        .then(() => {
          emitPlaybackEvent(this.el, "seeked");
          this.updateMediaSessionPosition({ force: true });
        })
        .catch((error) => {
          log.debug("[VideoPlayer] managed engine seek skipped:", error.message);
        });
    } else if (this.video) {
      this.seekNativeTo(target);
    }
  },

  seekNativeTo(time) {
    if (!this.video || this.contentType === "live") return false;

    this.nativeBufferingController.prepareSeek();
    this.video.currentTime = time;
    return true;
  },

  seekLiveTo(time) {
    if (!this.video || !Number.isFinite(Number(time))) return false;

    const target = Number(time);
    const ranges = this.video.seekable;
    if (!ranges || ranges.length === 0) return false;

    const rangeIndex = ranges.length - 1;
    const start = ranges.start(rangeIndex);
    const end = ranges.end(rangeIndex);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return false;

    this.video.currentTime = Math.max(start, Math.min(end - 0.05, target));
    return true;
  },

  getCurrentTime() {
    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return nativeEngine.getCurrentTime();

    const engine = this.getManagedPlaybackEngine();
    return engine?.getCurrentTime?.() ?? this.video?.currentTime ?? 0;
  },

  getDuration() {
    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return nativeEngine.getDuration();

    const engine = this.getManagedPlaybackEngine();
    const duration = engine?.getDuration?.() ?? this.video?.duration ?? 0;

    // Sanity check: if duration is absurd (>12 hours), use expected duration from DB
    const MAX_SANE_DURATION = 12 * 60 * 60; // 12 hours in seconds
    if (duration > MAX_SANE_DURATION && this.expectedDuration > 0) {
      return this.expectedDuration;
    }

    return duration;
  },

  getPlaybackRate() {
    if (!this.supportsPlaybackRateControl()) return 1;

    const playbackRate = Number(this.video?.playbackRate);
    return Number.isFinite(playbackRate) && playbackRate > 0 ? playbackRate : 1;
  },

  isPaused() {
    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return !nativeEngine.isPlaying();

    const engine = this.getManagedPlaybackEngine();
    if (engine) return !engine.isPlaying();
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
    this._disposePlaybackBridge?.();
    this._disposePlaybackBridge = null;
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

    this.nextEpisodeController?.destroy();
    this.nextEpisodeController = null;
    this.nativeBufferingController?.destroy();
    this.nativeBufferingController = null;

    if (this.keyboardManager) {
      this.keyboardManager.destroy();
      this.keyboardManager = null;
    }

    this.mediaSessionController?.destroy();
    this.mediaSessionController = null;

    const wakeLockController = this.screenWakeLockController;
    this.screenWakeLockController = null;
    void wakeLockController?.destroy();

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
