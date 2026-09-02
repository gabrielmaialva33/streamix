import { playerLogger as log } from "../core/logger.js";
import { getFileExtension } from "../media/stream_loader.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import {
  assertActivationHost,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "./playback_engine_activation.js";
import { createPlaybackEngineAdapter } from "./playback_engine_adapter.js";
import { resolvePlaybackResumeTime } from "./playback_engine_lifecycle.js";
import { loadAVPlayer } from "./playback_module_loader.js";
import { forgetRecommendedPlayer, recordPlayerSuccess } from "./player_preferences.js";

export const AVPLAYER_FALLBACK_BLOCKED_MESSAGE =
  "Formato de audio nao suportado. Tente novamente mais tarde.";
export const AVPLAYER_RECOVERY_FAILED_MESSAGE = "Não foi possível restaurar a reprodução.";

export const AVPLAYER_UI_TICK_MS = 125;
export const AVPLAYER_PROGRESS_TICK_MS = 10_000;
export const AVPLAYER_TRACK_DETECT_DELAY_MS = 500;

export const AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
  "applyAudioState",
  "canAttemptFallback",
  "cancelNativeAudioCheck",
  "detachNativeErrorHandler",
  "disablePiPForCanvasPlayback",
  "emitPlaybackEvent",
  "flushPlaybackMetrics",
  "getAVPlayer",
  "getAVPlayerMount",
  "getContentType",
  "getFallbackAttempts",
  "getOutputVolume",
  "getPresentation",
  "getProxyUrl",
  "getSourceType",
  "getStreamType",
  "getStreamUrl",
  "getSubtitleOffsetMs",
  "getTransitionController",
  "getVideo",
  "handlePlaybackEnded",
  "handlePlaybackPaused",
  "handlePlaybackStarted",
  "hasProbedAudioTrack",
  "initPlayer",
  "isAVPlayerAttempted",
  "isDestroyed",
  "isSwitchingToAVPlayer",
  "isUsingAVPlayer",
  "loadExternalSubtitle",
  "markAVPlayerAttempted",
  "markPlaying",
  "recordFallbackAttempt",
  "recordPlaybackError",
  "releaseEngine",
  "reportDebug",
  "reportLifecycle",
  "reportProgress",
  "resetNativeMediaElement",
  "resetNativeSubtitles",
  "savePlaybackPosition",
  "setAVPlayer",
  "setAudioTrack",
  "setSubtitleDelay",
  "setSubtitleTrack",
  "setUsingAVPlayer",
  "showPlaybackError",
  "syncPiPAvailability",
  "takeResumeTime",
  "teardownAVPlayer",
  "toAbsoluteUrl",
  "trackManagedEngine",
  "updateAudioTracks",
  "updateMediaSessionPosition",
  "updateSubtitleTracks",
  "updateTimeUI",
  "updateVolumeUI",
]);

const defaultDependencies = {
  createPlaybackEngineAdapter,
  forgetRecommendedPlayer,
  frameApi: {
    cancelAnimationFrame: (handle) => globalThis.cancelAnimationFrame(handle),
    requestAnimationFrame: (callback) => globalThis.requestAnimationFrame(callback),
  },
  getFileExtension,
  loadAVPlayer,
  recordPlayerSuccess,
  resolvePlaybackResumeTime,
  timerApi: globalThis,
};

/**
 * Activates the libmedia AVPlayer (WASM) engine.
 *
 * Owns AVPlayer construction and callbacks, the native-to-AVPlayer transaction
 * stages, AVPlayer-to-native recovery, runtime error policy, track detection,
 * the load profile and the rAF progress loop. Transaction ordering stays in the
 * shared PlaybackEngineTransitionController; circuit-breaker counters and the
 * teardown queue stay on the host.
 */
export class AvPlayerEngineActivation {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(
      host,
      AVPLAYER_ENGINE_ACTIVATION_HOST_METHODS,
      "AvPlayerEngineActivation",
    );
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;

    this.animating = false;
    this.frameHandle = null;
    this.lastProgressUpdate = 0;
    this.lastUiUpdate = 0;
  }

  get id() {
    return ENGINE_ID.AVPLAYER;
  }

  get selection() {
    return ENGINE_SELECTION.AVPLAYER;
  }

  /**
   * Initial AVPlayer selection. Reuses the session created by initPlayer and
   * deliberately bypasses fallback-only policy (circuit breaker, counters).
   */
  activate(request) {
    const { sessionId } = request;
    if (!this.host.isSessionCurrent(sessionId)) return Promise.resolve(false);

    const controller = this.host.getTransitionController();
    if (this.host.isSwitchingToAVPlayer() || controller?.active) {
      this.logger.debug("[VideoPlayer] AVPlayer startup transition already active");
      return Promise.resolve(false);
    }

    if (this.host.isUsingAVPlayer()) return Promise.resolve(this.host.getAVPlayer() ?? true);

    this.host.disablePiPForCanvasPlayback();
    this.host.markAVPlayerAttempted();
    this.host.reportDebug("start_avplayer_selected", { session_id: sessionId });

    return this.transition({
      key: "startup-avplayer",
      sessionId,
      initializeEngine: true,
      recordSuccess: true,
      capture: () => this.captureNativePlayback(),
    });
  }

  async tryFallback() {
    const controller = this.host.getTransitionController();
    if (this.host.isSwitchingToAVPlayer() || controller?.active) {
      this.logger.debug("[VideoPlayer] Already switching to AVPlayer, skipping fallback");
      return false;
    }

    if (!this.host.canAttemptFallback()) {
      this.logger.debug("[VideoPlayer] Circuit breaker prevented fallback attempt");
      this.host.showPlaybackError(AVPLAYER_FALLBACK_BLOCKED_MESSAGE);
      return false;
    }

    if (this.host.isAVPlayerAttempted() || this.host.isUsingAVPlayer()) {
      this.logger.debug("[VideoPlayer] AVPlayer fallback already attempted, skipping");
      return false;
    }

    this.host.disablePiPForCanvasPlayback();
    this.host.markAVPlayerAttempted();
    this.host.recordFallbackAttempt();
    this.host.cancelNativeAudioCheck();

    this.logger.debug("[VideoPlayer] Attempting AVPlayer fallback (seamless)", {
      currentStreamType: this.host.getStreamType(),
      contentType: this.host.getContentType(),
      proxyUrl: this.host.getProxyUrl(),
      streamUrl: this.host.getStreamUrl(),
    });
    this.host.reportDebug("try_avplayer_fallback", {
      fallback_attempts: this.host.getFallbackAttempts(),
    });

    return this.transition({
      key: "native-to-avplayer-fallback",
      fallback: true,
      capture: () => this.captureNativePlayback(),
    });
  }

  async switchWithTrack(trackType, trackIndex, seekTime, shouldPlay) {
    const controller = this.host.getTransitionController();
    if (this.host.isSwitchingToAVPlayer() || controller?.active) {
      this.logger.debug("[VideoPlayer] Already switching to AVPlayer, ignoring duplicate call");
      return false;
    }

    this.host.disablePiPForCanvasPlayback();
    this.host.markAVPlayerAttempted();

    return this.transition({
      key: `native-to-avplayer-${trackType}-track`,
      capture: () => ({
        resumeTime: Number(seekTime) || 0,
        shouldPlay: shouldPlay === true,
      }),
      initializeEngine: true,
      showLoading: true,
      trackIndex,
      trackType,
    });
  }

  transition({
    capture,
    fallback = false,
    initializeEngine = false,
    key,
    recordSuccess = fallback,
    sessionId = null,
    showLoading = false,
    trackIndex = null,
    trackType = null,
  }) {
    const controller = this.host.getTransitionController();
    if (!controller) return Promise.resolve(false);

    return controller.transition({
      key,
      capture,
      sessionId,
      prepare: ({ capture: playback, sessionId }) => {
        const presentation = this.host.getPresentation();
        if (showLoading) presentation?.showLoading();
        else presentation?.hideError();

        this.host.reportLifecycle("player_engine_selected", {
          engine: "avplayer",
          fallback,
          session_id: sessionId,
        });

        if (fallback) {
          this.host.getVideo()?.pause();
          this.host.detachNativeErrorHandler();
        }

        this.host.resetNativeMediaElement();
        this.host.resetNativeSubtitles();
        this.logger.debug("[VideoPlayer] Preparing AVPlayer transition", {
          key,
          resumeTime: playback?.resumeTime ?? 0,
          shouldPlay: playback?.shouldPlay === true,
        });
      },
      releasePrevious: async () => {
        const previous = this.host.getAVPlayer();
        if (!previous) return;

        this.host.setAVPlayer(null);
        await this.host.teardownAVPlayer(previous);
      },
      createEngine: (context) =>
        this.createEngine(context, {
          recordSuccess,
          resumeTime: context.capture?.resumeTime ?? 0,
          trackSwitch: Boolean(trackType),
        }),
      initializeEngine: initializeEngine ? ({ engine }) => engine.init() : null,
      loadEngine: async ({ engine }) => {
        const streamUrl = this.host.getStreamUrl();
        const proxyUrl = this.host.getProxyUrl();
        const sourceType = this.host.getSourceType();
        const url = proxyUrl ? this.host.toAbsoluteUrl(proxyUrl) : streamUrl;
        const extension = trackType
          ? sourceType === "gindex"
            ? "mkv"
            : streamUrl.split(".").pop()?.split("?")[0] || "mkv"
          : this.deps.getFileExtension(streamUrl, sourceType, this.host.getStreamType());
        const isLive = this.host.getContentType() === "live";
        await engine.load(url, this.buildLoadOptions(extension, isLive));
      },
      registerEngine: ({ engine }) => {
        this.host.setAVPlayer(engine);
        this.host.trackManagedEngine(ENGINE_ID.AVPLAYER, engine);
      },
      restoreEngine: async ({ capture: playback, engine }) => {
        const resumeTime = playback?.resumeTime ?? 0;

        if (fallback && resumeTime > 0) await engine.seek(resumeTime);
        engine.setVolume(this.host.getOutputVolume());
        if (!fallback && resumeTime > 0) await engine.seek(resumeTime);

        if (trackType === "audio" && this.host.hasProbedAudioTrack(trackIndex)) {
          const tracks = await this.host.updateAudioTracks();
          if (tracks?.[trackIndex]) await this.host.setAudioTrack(trackIndex);
        } else if (trackType === "subtitle") {
          const tracks = await this.host.updateSubtitleTracks();
          if (trackIndex === -1 || tracks?.[trackIndex]) {
            await this.host.setSubtitleTrack(trackIndex);
          }
        }
      },
      activateEngine: async ({ capture: playback, engine }) => {
        this.host.setUsingAVPlayer(true);
        this.host.getVideo()?.classList.add("hidden");

        if (playback?.shouldPlay === true) await engine.play();
        else this.host.handlePlaybackPaused();
      },
      complete: ({ capture: playback, engine, sessionId }) => {
        this.startTimeUpdates();
        this.host.updateMediaSessionPosition({ force: true });
        void this.detectTracks(sessionId);
        this.host.getPresentation()?.hideLoading();
        this.logger.debug("[VideoPlayer] AVPlayer transition completed", {
          key,
          resumeTime: playback?.resumeTime ?? 0,
          trackIndex,
          trackType,
        });
        return engine;
      },
      rollbackEngine: ({ engine }) => {
        if (this.host.getAVPlayer() === engine) this.host.setAVPlayer(null);
        this.host.releaseEngine(ENGINE_ID.AVPLAYER);
        this.stopTimeUpdates();
        this.host.setUsingAVPlayer(false);
      },
      onFailure: (error, context) => {
        // The controller awaits this handler while its own transition promise
        // is still pending, so recovery is queued behind it, never awaited here.
        void this.recoverToNative({
          sessionId: context.sessionId,
          avPlayer: null,
          error,
          resumeTime: context.capture?.resumeTime ?? 0,
          skipTeardown: true,
        });
      },
    });
  }

  async createEngine(context, { recordSuccess = false, resumeTime = 0, trackSwitch = false } = {}) {
    const { AVPlayerWrapper } = await this.deps.loadAVPlayer();
    const mount = this.host.getAVPlayerMount();
    if (!mount) throw new Error("AVPlayer mount element (#avplayer-mount) not found in template");

    mount.replaceChildren();
    mount.classList.remove("hidden");

    const isCurrent = () => this.host.isSessionCurrent(context.sessionId);
    let avPlayer = null;
    const wrapper = new AVPlayerWrapper({
      container: mount,
      onReady: () => {
        if (!isCurrent()) return;
        this.logger.debug(
          trackSwitch
            ? "[VideoPlayer] AVPlayer ready for track switch"
            : "[VideoPlayer] AVPlayer ready",
        );
      },
      onPlay: () => {
        if (!isCurrent()) return;
        const presentation = this.host.getPresentation();
        presentation?.hideLoading();
        presentation?.updatePlayPauseUI(false);
        this.startTimeUpdates();
        this.host.handlePlaybackStarted();
        this.host.markPlaying();
        this.host.emitPlaybackEvent("play");

        if (recordSuccess) {
          const sourceType = this.host.getSourceType();
          const streamType = this.host.getStreamType();
          this.deps.recordPlayerSuccess(this.contentKey(), "avplayer", { sourceType, streamType });
        }
      },
      onPause: () => {
        if (!isCurrent()) return;
        this.host.getPresentation()?.updatePlayPauseUI(true);
        this.host.handlePlaybackPaused();
        this.host.emitPlaybackEvent("pause");
      },
      onError: (error) => this.handleEngineError({ context, avPlayer, error, resumeTime }),
      onTimeUpdate: () => {
        if (!isCurrent()) return;
        this.host.updateTimeUI();
      },
      onEnded: () => {
        if (!isCurrent()) return;
        this.host.getPresentation()?.updatePlayPauseUI(true);
        this.stopTimeUpdates();
        this.host.handlePlaybackEnded();
        this.host.flushPlaybackMetrics("completed");
      },
    });

    avPlayer = this.deps.createPlaybackEngineAdapter({
      id: ENGINE_ID.AVPLAYER,
      engine: wrapper,
    });
    return avPlayer;
  }

  recoverToNative({ sessionId, avPlayer, error, resumeTime = 0, skipTeardown = false }) {
    if (!this.host.isSessionCurrent(sessionId)) return Promise.resolve(false);

    const controller = this.host.getTransitionController();
    if (!controller) return Promise.resolve(false);

    return controller.recover({
      key: "avplayer-to-native-recovery",
      sourceSessionId: sessionId,
      engine: skipTeardown ? null : avPlayer,
      capture: () => ({
        error,
        resumeTime: this.deps.resolvePlaybackResumeTime(avPlayer, resumeTime),
      }),
      prepare: ({ capture }) => {
        this.logger.error("[VideoPlayer] AVPlayer failed, returning to native playback:", error);
        this.host.recordPlaybackError();

        const contentKey = this.contentKey();
        if (contentKey) this.deps.forgetRecommendedPlayer(contentKey);
        if (this.host.getContentType() === "vod" && capture.resumeTime > 0) {
          this.host.savePlaybackPosition(capture.resumeTime);
        }
      },
      releasePrevious: () => {
        this.stopTimeUpdates();
        if (!avPlayer || this.host.getAVPlayer() === avPlayer) this.host.setAVPlayer(null);
        this.host.releaseEngine(ENGINE_ID.AVPLAYER);
      },
      restoreNative: () => this.restoreNativePresentation(),
      activateNative: ({ sessionId: nativeSessionId }) => {
        if (this.host.isDestroyed() || !this.host.isSessionCurrent(nativeSessionId)) return false;
        this.host.initPlayer({ sessionId: nativeSessionId });
        return true;
      },
      complete: () => true,
      onFailure: (recoveryError, context) => {
        this.logger.error("[VideoPlayer] Failed to restore native playback:", recoveryError);
        this.restoreNativePresentation();
        const failureSessionId = context.sessionId ?? context.sourceSessionId;
        if (this.host.isSessionCurrent(failureSessionId)) {
          this.host.showPlaybackError(AVPLAYER_RECOVERY_FAILED_MESSAGE);
        }
      },
    });
  }

  handleEngineError({ context, avPlayer, error, resumeTime = 0 }) {
    const sessionId = context?.sessionId;
    if (!this.host.isSessionCurrent(sessionId)) return;

    const controller = this.host.getTransitionController();
    const snapshot = controller?.snapshot?.();
    const pendingNativeToAVPlayer =
      controller?.active &&
      snapshot?.key?.startsWith("native-to-avplayer") &&
      snapshot?.phase !== "completed";

    if (pendingNativeToAVPlayer) {
      void controller.cancel("avplayer_error").then((cancelled) => {
        if (!cancelled || !this.host.isSessionCurrent(sessionId)) return false;

        return this.recoverToNative({
          sessionId,
          avPlayer: null,
          error,
          resumeTime,
          skipTeardown: true,
        });
      });
      return;
    }

    void this.recoverToNative({ sessionId, avPlayer, error, resumeTime });
  }

  async detectTracks(sessionId = this.host.getSessionId()) {
    if (!this.host.getAVPlayer()) return;

    const isCurrent = () => this.host.isSessionCurrent(sessionId);

    try {
      await new Promise((resolve) =>
        this.deps.timerApi.setTimeout(resolve, AVPLAYER_TRACK_DETECT_DELAY_MS),
      );
      if (!isCurrent() || !this.host.getAVPlayer()) return;

      await this.host.updateAudioTracks();
      if (!isCurrent()) return;

      await this.host.updateSubtitleTracks();
      if (!isCurrent()) return;

      await this.host.setSubtitleDelay(this.host.getSubtitleOffsetMs());
    } catch (error) {
      this.logger.warn("[VideoPlayer] Failed to refresh AVPlayer tracks:", error);
    }

    await this.host.loadExternalSubtitle(sessionId);
  }

  buildLoadOptions(ext, isLive) {
    // GIndex 4K MKV is the only path that genuinely needs the heavier
    // load profile: large `moov`, MKV cluster probe, and the BEAM-side
    // proxy adds latency on top of upstream redirects. 2-min ceiling +
    // 8 MB preload + aggressive retry keeps the player alive on flaky
    // links. Everything else — including Xtream VOD MP4 — keeps the
    // libmedia defaults: a single blocking prefetch sits in TCP
    // slow-start while the upstream throttles, so playback waits for the
    // whole prefetch before the first frame. libmedia's natural small
    // range walk is faster end-to-end.
    const isHeavyGIndexMkv = !isLive && this.host.getSourceType() === "gindex" && ext === "mkv";

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
  }

  startTimeUpdates() {
    this.stopTimeUpdates();
    this.animating = true;
    this.lastProgressUpdate = 0;
    this.lastUiUpdate = 0;

    // The progress bar does not need 60Hz updates; ~8Hz keeps the marker
    // visually continuous without burning battery on phones.
    const updateLoop = (timestamp) => {
      if (!this.animating) return;

      if (this.host.isUsingAVPlayer() && this.host.getAVPlayer()) {
        if (timestamp - this.lastUiUpdate >= AVPLAYER_UI_TICK_MS) {
          this.lastUiUpdate = timestamp;
          this.host.updateTimeUI();
        }

        if (
          this.host.getContentType() === "vod" &&
          timestamp - this.lastProgressUpdate >= AVPLAYER_PROGRESS_TICK_MS
        ) {
          this.lastProgressUpdate = timestamp;
          this.host.reportProgress();
        }
      }

      this.frameHandle = this.deps.frameApi.requestAnimationFrame(updateLoop);
    };

    this.frameHandle = this.deps.frameApi.requestAnimationFrame(updateLoop);
  }

  stopTimeUpdates() {
    const wasAnimating = this.animating;
    this.animating = false;
    if (this.frameHandle != null) {
      this.deps.frameApi.cancelAnimationFrame(this.frameHandle);
      this.frameHandle = null;
    }
    return wasAnimating;
  }

  restoreNativePresentation() {
    const mount = this.host.getAVPlayerMount();
    if (mount) {
      mount.replaceChildren();
      mount.classList.add("hidden");
    }

    this.host.getVideo()?.classList.remove("hidden");
    this.host.setUsingAVPlayer(false);
    this.host.applyAudioState();
    this.host.updateVolumeUI();
    this.host.syncPiPAvailability();
  }

  destroy() {
    this.stopTimeUpdates();
  }

  captureNativePlayback() {
    const video = this.host.getVideo();
    const resumeTime = this.host.takeResumeTime(video?.currentTime || 0);
    return {
      resumeTime,
      shouldPlay: true,
      wasPlaying: !video?.paused || resumeTime > 0,
    };
  }

  contentKey() {
    return this.host.getSourceType() === "gindex" ? "gindex" : this.host.getStreamType();
  }
}

export function createAvPlayerEngineActivation(options) {
  return new AvPlayerEngineActivation(options);
}
