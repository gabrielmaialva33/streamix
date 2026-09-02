import { playerLogger as log } from "../core/logger.js";
import { NativeBufferManager } from "../media/native_buffer.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import {
  configureNativePlaybackElement,
  waitForNativeReady,
  waitForNativeSeek,
} from "./native_playback_controller.js";
import { createNativePlaybackEngine } from "./native_playback_engine.js";
import { buildNativePlaybackSnapshot } from "./native_playback_snapshot.js";
import {
  assertActivationHost,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "./playback_engine_activation.js";
import { isAppleTouchDevice, scheduleLowPriority } from "./playback_environment.js";
import { loadAVPlayer } from "./playback_module_loader.js";
import { recordPlayerSuccess } from "./player_preferences.js";

export const NATIVE_PLAYBACK_MESSAGES = Object.freeze({
  ABORTED: "Reproducao cancelada",
  FAILED: "Falha na reproducao",
  NETWORK: "Erro de rede - verifique sua conexao",
  UNSUPPORTED: "Formato nao suportado pelo navegador",
});

export const NATIVE_AUDIO_CHECK_DELAY_MS = 2_000;
export const NATIVE_SUCCESS_CONFIRM_MS = 5_000;
export const NATIVE_METADATA_PROBE_TIMEOUT_MS = 5_000;

// HTMLMediaElement error codes. Spelled out so the activation stays usable
// without the browser global.
const MEDIA_ERR_ABORTED = 1;
const MEDIA_ERR_NETWORK = 2;
const MEDIA_ERR_DECODE = 3;
const MEDIA_ERR_SRC_NOT_SUPPORTED = 4;

export const NATIVE_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
  "getContentType",
  "getNativeBufferManager",
  "getNativeBufferingController",
  "getNativePlaybackEngine",
  "getPresentation",
  "getSourceType",
  "getStreamType",
  "getVideo",
  "isAVPlayerAttempted",
  "isDestroyed",
  "isSwitchingToAVPlayer",
  "isUsingAVPlayer",
  "lifecycleLogsEnabled",
  "loadNativeExternalSubtitle",
  "probeMetadataInBackground",
  "recordPlaybackError",
  "registerMediaElementEngine",
  "reportLifecycle",
  "setNativeBufferManager",
  "setNativePlaybackEventsSuppressed",
  "setNativeTouchControls",
  "showPlaybackError",
  "syncPiPAvailability",
  "takeResumeTime",
  "tryAVPlayerFallback",
]);

const defaultDependencies = {
  buildNativePlaybackSnapshot,
  configureNativePlaybackElement,
  createNativeBufferManager: (video, callbacks) => new NativeBufferManager(video, callbacks),
  createNativePlaybackEngine,
  isAppleTouchDevice,
  loadAVPlayer,
  recordPlayerSuccess,
  scheduleLowPriority,
  timerApi: globalThis,
  waitForNativeReady,
  waitForNativeSeek,
};

/**
 * Activates playback on the bare `<video>` element.
 *
 * Owns the concrete NativePlaybackEngine, the native buffer monitor, the
 * post-start audio probe, the deferred GIndex track probe and the codec-memory
 * confirmation timer. Cross-engine policy (AVPlayer fallback, presentation)
 * is reached only through the explicit host surface.
 */
export class NativeEngineActivation {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(
      host,
      NATIVE_ENGINE_ACTIVATION_HOST_METHODS,
      "NativeEngineActivation",
    );
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;

    this.audioCheckTimer = null;
    this.errorHandler = null;
    this.metadataProbeCancel = null;
    this.successTimer = null;
  }

  get id() {
    return ENGINE_ID.NATIVE;
  }

  get selection() {
    return ENGINE_SELECTION.NATIVE;
  }

  createEngine() {
    return this.deps.createNativePlaybackEngine({
      video: this.host.getVideo(),
      beforePause: () => this.host.getNativeBufferManager()?.markIntentionalPause(),
      beforeSeek: () => this.host.getNativeBufferingController()?.prepareSeek(),
      resetSourceOnDestroy: false,
    });
  }

  activate(request) {
    const { sessionId, url } = request;
    const video = this.host.getVideo();

    this.host.setNativePlaybackEventsSuppressed(false);
    this.host.syncPiPAvailability();
    const resumeTime = this.host.takeResumeTime();
    this.logger.info("Playing with native video element, url:", url);
    this.host.setNativeTouchControls(this.deps.isAppleTouchDevice());
    this.deps.configureNativePlaybackElement(video, { resumeTime });

    const nativeEngine =
      this.host.getNativePlaybackEngine() ??
      this.host.registerMediaElementEngine(ENGINE_ID.NATIVE, this.createEngine(), {
        ownsEngine: true,
      });
    this.host.reportLifecycle("player_engine_selected", {
      engine: ENGINE_ID.NATIVE,
      session_id: sessionId,
    });
    nativeEngine.load(url);
    this.trace("native_source_attached", sessionId);

    const playHandler = () => {
      if (!this.host.isSessionCurrent(sessionId)) return;

      this.logger.debug("Native playback started");
      this.trace("native_playing", sessionId);
      const presentation = this.host.getPresentation();
      presentation?.hideLoading();
      presentation?.hideError();
      video.removeEventListener("playing", playHandler);

      this.ensureBufferManager(video);

      if (this.shouldCheckAudio()) {
        this.checkAudioAndFallback(sessionId);
      }

      if (this.host.getSourceType() === "gindex") {
        this.scheduleMetadataProbe();
      }

      if (!this.shouldCheckAudio()) {
        this.scheduleSuccessConfirmation(sessionId, video);
      }
    };

    const errorHandler = () => {
      if (!this.host.isSessionCurrent(sessionId)) return;

      if (this.host.isUsingAVPlayer() || this.host.isSwitchingToAVPlayer()) {
        this.logger.debug(
          "[VideoPlayer] Ignoring stale native video error during AVPlayer playback",
        );
        return;
      }

      const message = this.resolveMediaError(video.error);
      if (message == null) return;

      this.host.showPlaybackError(message);
      video.removeEventListener("error", errorHandler);
    };

    this.detachErrorHandler();
    this.errorHandler = errorHandler;

    video.addEventListener("playing", playHandler);
    video.addEventListener("error", errorHandler);
    video.addEventListener(
      "loadedmetadata",
      () => {
        if (!this.host.isSessionCurrent(sessionId)) return;
        this.trace("native_metadata_loaded", sessionId);
        this.host.getPresentation()?.hideLoading();

        if (this.host.getSourceType() === "torrent") {
          this.host.loadNativeExternalSubtitle(sessionId);
        }
      },
      { once: true },
    );

    this.playAfterResume(sessionId, resumeTime).catch((error) => {
      if (error?.name === "AbortError") return;
      this.logger.debug("Native playback start failed:", error);
    });

    return true;
  }

  async playAfterResume(sessionId, resumeTime = this.host.takeResumeTime()) {
    const video = this.host.getVideo();
    if (!video || !this.host.isSessionCurrent(sessionId)) return;

    const isCurrent = () => this.host.isSessionCurrent(sessionId);

    if (resumeTime > 0) {
      this.logger.debug("Resuming from saved position before play:", resumeTime);
      this.trace("native_resume_prepare", sessionId, { resume_time: resumeTime });
      await this.deps.waitForNativeReady({ video, isCurrent });
      if (!isCurrent()) return;
      this.trace("native_resume_ready", sessionId, { resume_time: resumeTime });
      await this.deps.waitForNativeSeek({
        video,
        targetTime: resumeTime,
        isCurrent,
        onSeekError: (error) =>
          this.logger.debug("[VideoPlayer] Native seek before play failed:", error.message),
      });
      if (!isCurrent()) return;
      this.trace("native_resume_seeked", sessionId, { resume_time: resumeTime });
    }

    if (!isCurrent()) return;

    try {
      this.trace("native_play_request", sessionId, { resume_time: resumeTime });
      const nativeEngine = this.host.getNativePlaybackEngine();
      await (nativeEngine ? nativeEngine.play() : video.play());
      if (!isCurrent()) return;
      this.trace("native_play_resolved", sessionId, { resume_time: resumeTime });
    } catch (error) {
      if (!isCurrent()) return;
      if (error?.name === "AbortError") return;
      this.trace("native_play_rejected", sessionId, {
        resume_time: resumeTime,
        error_name: error?.name,
        error_message: error?.message,
      });
      this.logger.debug("Native play prevented:", error);
      const presentation = this.host.getPresentation();
      presentation?.hideLoading();

      if (error?.name === "NotSupportedError" && this.canTryAVPlayerForCurrentVod()) {
        this.logger.debug("[VideoPlayer] Native play failed, AVPlayer fallback will be attempted");
        return;
      }

      if (error?.name === "NotAllowedError") {
        // Keep the standard bottom controls visible so the user can start
        // playback without covering the video with an autoplay overlay.
        presentation?.keepControlsVisible();
      } else {
        this.host.showPlaybackError(`Falha ao iniciar reproducao: ${error?.message}`);
      }
    }
  }

  canTryAVPlayerForCurrentVod() {
    if (this.host.getContentType() !== "vod" || this.host.isAVPlayerAttempted()) return false;

    const streamType = this.host.getStreamType();
    return (
      streamType === "mp4" ||
      streamType === "mkv" ||
      this.host.getSourceType() === "gindex" ||
      streamType === "unknown"
    );
  }

  shouldCheckAudio() {
    if (this.host.getContentType() !== "vod") return false;

    const sourceType = this.host.getSourceType();
    const streamType = this.host.getStreamType();

    // Xtream VOD ships H.264 + AAC by default through XUI, both of
    // which `<video>` decodes natively across every supported browser.
    // The audio-issue probe is meant to catch GIndex / unknown rips
    // that carry AC3/EAC3/DTS — running it on Xtream MP4 only adds
    // false positives (e.g. brief silent first frames) that then
    // wrongly demote the player to AVPlayer's libmedia WASM path,
    // which is the 30-55 s startup we are trying to avoid.
    if (sourceType === "xtream" && streamType === "mp4") return false;

    return (
      sourceType === "gindex" ||
      streamType === "mp4" ||
      streamType === "mkv" ||
      streamType === "unknown"
    );
  }

  checkAudioAndFallback(sessionId) {
    this.cancelAudioCheck();

    this.audioCheckTimer = this.deps.timerApi.setTimeout(async () => {
      this.audioCheckTimer = null;

      try {
        if (!this.host.isSessionCurrent(sessionId)) return;

        this.trace("native_audio_check_start", sessionId);
        const { detectAudioIssue } = await this.deps.loadAVPlayer();
        if (!this.host.isSessionCurrent(sessionId)) return;

        const hasAudioIssue = await detectAudioIssue(this.host.getVideo());
        if (!this.host.isSessionCurrent(sessionId)) return;

        this.trace("native_audio_check_result", sessionId, { has_audio_issue: hasAudioIssue });

        if (hasAudioIssue) {
          this.logger.debug("[VideoPlayer] Audio issue detected, auto-switching to AVPlayer");
          this.host.tryAVPlayerFallback();
        } else {
          this.logger.debug("[VideoPlayer] Audio working correctly");
        }
      } catch (error) {
        this.logger.warn("[VideoPlayer] Could not check audio:", error);
      }
    }, NATIVE_AUDIO_CHECK_DELAY_MS);
  }

  cancelAudioCheck() {
    if (this.audioCheckTimer == null) return false;
    this.deps.timerApi.clearTimeout(this.audioCheckTimer);
    this.audioCheckTimer = null;
    return true;
  }

  cancelBackgroundWork() {
    this.cancelAudioCheck();
    this.metadataProbeCancel?.();
    this.metadataProbeCancel = null;
    if (this.successTimer != null) {
      this.deps.timerApi.clearTimeout(this.successTimer);
      this.successTimer = null;
    }
  }

  detachErrorHandler() {
    if (!this.errorHandler) return false;
    this.host.getVideo()?.removeEventListener("error", this.errorHandler);
    this.errorHandler = null;
    return true;
  }

  destroy() {
    this.cancelBackgroundWork();
    this.detachErrorHandler();
  }

  ensureBufferManager(video) {
    if (this.host.getNativeBufferManager() || this.host.getContentType() !== "vod") return;

    // Native Buffer Manager for MP4/MKV streams.
    const manager = this.deps.createNativeBufferManager(video, {
      onBufferHealthChange: (status) => {
        this.logger.debug(
          `[NativeBuffer] Health: ${status.health}, buffer: ${status.bufferAhead.toFixed(1)}s`,
        );
      },
      onStall: (info) => {
        if (!info.isRealStall) {
          this.logger.debug(`[NativeBuffer] Brief buffer wait #${info.totalStalls}`);
          return;
        }

        if (!info.shouldRecover) {
          this.logger.debug(`[NativeBuffer] Stall observed #${info.totalStalls}`);
          return;
        }

        this.logger.warn(`[NativeBuffer] Stall detected #${info.totalStalls}`);
        this.host.getPresentation()?.showLoading();
      },
      onRecovery: () => {
        this.host.getPresentation()?.hideLoading();
      },
    });
    this.host.setNativeBufferManager(manager);
    manager.start();
    this.logger.info("[VideoPlayer] Native buffer monitoring enabled");
  }

  scheduleMetadataProbe() {
    // For GIndex content, probe metadata in background to detect audio and
    // subtitle tracks. Native playback starts fast while tracks are detected.
    this.metadataProbeCancel?.();
    this.metadataProbeCancel = this.deps.scheduleLowPriority(
      () => {
        this.metadataProbeCancel = null;
        if (!this.host.isDestroyed() && !this.host.isUsingAVPlayer()) {
          this.host.probeMetadataInBackground();
        }
      },
      { timeout: NATIVE_METADATA_PROBE_TIMEOUT_MS },
    );
  }

  scheduleSuccessConfirmation(sessionId, video) {
    // Record successful native playback after a short confirmation window so
    // Device Codec Memory learns that native works for this content type.
    if (this.successTimer != null) this.deps.timerApi.clearTimeout(this.successTimer);
    this.successTimer = this.deps.timerApi.setTimeout(() => {
      this.successTimer = null;
      if (!this.host.isSessionCurrent(sessionId) || this.host.isUsingAVPlayer() || video.paused) {
        return;
      }

      const sourceType = this.host.getSourceType();
      const streamType = this.host.getStreamType();
      const contentKey = sourceType === "gindex" ? "gindex" : streamType;
      this.deps.recordPlayerSuccess(contentKey, "native", { sourceType, streamType });
    }, NATIVE_SUCCESS_CONFIRM_MS);
  }

  resolveMediaError(error) {
    this.host.recordPlaybackError();
    if (!error) return NATIVE_PLAYBACK_MESSAGES.FAILED;

    switch (error.code) {
      case MEDIA_ERR_ABORTED:
        return NATIVE_PLAYBACK_MESSAGES.ABORTED;
      case MEDIA_ERR_NETWORK:
        return NATIVE_PLAYBACK_MESSAGES.NETWORK;
      case MEDIA_ERR_DECODE:
      case MEDIA_ERR_SRC_NOT_SUPPORTED:
        // Try AVPlayer for any VOD content that may have unsupported codecs.
        if (this.canTryAVPlayerForCurrentVod()) {
          this.logger.debug("[VideoPlayer] Format not supported, trying AVPlayer fallback");
          this.host.tryAVPlayerFallback();
          return null;
        }
        return NATIVE_PLAYBACK_MESSAGES.UNSUPPORTED;
      default:
        return NATIVE_PLAYBACK_MESSAGES.FAILED;
    }
  }

  trace(stage, sessionId, extra = {}) {
    if (!this.host.lifecycleLogsEnabled()) return;

    const payload = {
      session_id: sessionId,
      ...this.deps.buildNativePlaybackSnapshot(this.host.getVideo()),
      ...extra,
    };

    this.logger.debug(`[VideoPlayer] ${stage}`, payload);
    this.host.reportLifecycle(stage, payload);
  }
}

export function createNativeEngineActivation(options) {
  return new NativeEngineActivation(options);
}
