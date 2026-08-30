import { playerLogger as defaultLogger } from "../core/logger.js";
import { emitPlaybackEvent as defaultEmitPlaybackEvent } from "./playback_bridge.js";
import { clampSeekTime, relativeSeekTarget } from "./playback_time.js";
import { savePlaybackRate as defaultSavePlaybackRate } from "./player_preferences.js";

const MAX_SANE_DURATION_SECONDS = 12 * 60 * 60;
const NATIVE_HLS_MIME_TYPE = "application/vnd.apple.mpegurl";

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlaybackCommandController requires ${name}`);
  }

  return value;
}

function optionalCallback(value, fallback = () => {}) {
  return typeof value === "function" ? value : fallback;
}

function safely(callback, ...args) {
  try {
    callback(...args);
  } catch {
    // Diagnostics must never turn a command failure into another failure.
  }
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

export class PlaybackCommandController {
  constructor({
    getRoot,
    getVideo,
    getContentType,
    getExpectedDuration = () => 0,
    getManagedPlaybackEngine,
    getNativePlaybackEngine,
    rejectViewerTransportControl,
    isWatchPartySyncHeld = () => false,
    supportsPlaybackRateControl,
    isPartyMode = () => false,
    getAudioController = () => null,
    getNativeBufferManager = () => null,
    getNativeBufferingController = () => null,
    getPlayerUiController = () => null,
    getPlayerUi = () => null,
    setPlaybackSystemState,
    updateMediaSessionPosition,
    pushEvent,
    emitPlaybackEvent = defaultEmitPlaybackEvent,
    savePlaybackRate = defaultSavePlaybackRate,
    onDebug = (...args) => defaultLogger.debug(...args),
    onError = (...args) => defaultLogger.error(...args),
  } = {}) {
    this.getRoot = requiredCallback(getRoot, "getRoot");
    this.getVideo = requiredCallback(getVideo, "getVideo");
    this.getContentType = requiredCallback(getContentType, "getContentType");
    this.getExpectedDuration = requiredCallback(getExpectedDuration, "getExpectedDuration");
    this.getManagedPlaybackEngine = requiredCallback(
      getManagedPlaybackEngine,
      "getManagedPlaybackEngine",
    );
    this.getNativePlaybackEngine = requiredCallback(
      getNativePlaybackEngine,
      "getNativePlaybackEngine",
    );
    this.rejectViewerTransportControl = requiredCallback(
      rejectViewerTransportControl,
      "rejectViewerTransportControl",
    );
    this.isWatchPartySyncHeld = requiredCallback(isWatchPartySyncHeld, "isWatchPartySyncHeld");
    this.supportsPlaybackRateControl = requiredCallback(
      supportsPlaybackRateControl,
      "supportsPlaybackRateControl",
    );
    this.isPartyMode = requiredCallback(isPartyMode, "isPartyMode");
    this.getAudioController = requiredCallback(getAudioController, "getAudioController");
    this.getNativeBufferManager = requiredCallback(
      getNativeBufferManager,
      "getNativeBufferManager",
    );
    this.getNativeBufferingController = requiredCallback(
      getNativeBufferingController,
      "getNativeBufferingController",
    );
    this.getPlayerUiController = requiredCallback(getPlayerUiController, "getPlayerUiController");
    this.getPlayerUi = requiredCallback(getPlayerUi, "getPlayerUi");
    this.setPlaybackSystemState = requiredCallback(
      setPlaybackSystemState,
      "setPlaybackSystemState",
    );
    this.updateMediaSessionPosition = requiredCallback(
      updateMediaSessionPosition,
      "updateMediaSessionPosition",
    );
    this.pushEvent = requiredCallback(pushEvent, "pushEvent");
    this.emitPlaybackEvent = requiredCallback(emitPlaybackEvent, "emitPlaybackEvent");
    this.savePlaybackRate = requiredCallback(savePlaybackRate, "savePlaybackRate");
    this.onDebug = optionalCallback(onDebug);
    this.onError = optionalCallback(onError);
    this._destroyed = false;
  }

  get destroyed() {
    return this._destroyed;
  }

  async togglePlayPause({ remote = false } = {}) {
    if (this._destroyed) return false;

    const options = { remote: Boolean(remote) };
    if (this.rejectViewerTransportControl(options)) return false;
    if (options.remote && this.isWatchPartySyncHeld() && this.isPaused()) return false;

    const engine = this.getManagedPlaybackEngine();

    if (engine) {
      try {
        const isPlaying = engine.isPlaying();
        this.debug("[VideoPlayer] togglePlayPause: managed engine isPlaying =", isPlaying);

        if (isPlaying) {
          await engine.pause();
          this.setPlaybackSystemState("paused");
        } else {
          await engine.play();
          this.setPlaybackSystemState("playing");
        }
      } catch (error) {
        this.error("[VideoPlayer] managed engine play/pause failed:", error);
        return false;
      }

      return undefined;
    }

    const video = this.getVideo();
    if (!video) return false;

    if (video.paused) {
      try {
        await video.play();
        return true;
      } catch (error) {
        if (error?.name !== "AbortError") {
          this.debug("[VideoPlayer] togglePlayPause play() failed:", errorMessage(error));
        }
        return false;
      }
    }

    try {
      this.getNativeBufferManager()?.markIntentionalPause?.();
      video.pause();
      return true;
    } catch (error) {
      this.error("[VideoPlayer] native pause failed:", error);
      return false;
    }
  }

  toggleMute() {
    if (this._destroyed) return false;

    try {
      const audioState = this.getAudioController()?.toggleMute?.();
      if (!audioState) return false;

      this.pushEvent("mute_toggled", { muted: audioState.muted === true });
      return undefined;
    } catch (error) {
      this.error("[VideoPlayer] mute toggle failed:", error);
      return false;
    }
  }

  adjustVolume(delta) {
    if (this._destroyed) return false;

    const normalizedDelta = Number(delta);
    if (!Number.isFinite(normalizedDelta)) return false;

    try {
      const audioState = this.getAudioController()?.adjustVolume?.(normalizedDelta);
      if (!audioState) return false;

      const volume = Number(audioState.volume);
      this.pushEvent("volume_changed", {
        volume: Number.isFinite(volume) ? Math.round(volume * 100) : 0,
      });
      return undefined;
    } catch (error) {
      this.error("[VideoPlayer] volume adjustment failed:", error);
      return false;
    }
  }

  seek(seconds, { remote = false } = {}) {
    if (this._destroyed) return false;

    const options = { remote: Boolean(remote) };
    if (this.rejectViewerTransportControl(options)) return false;
    if (this.getContentType() === "live") return false;

    const delta = Number(seconds);
    if (!Number.isFinite(delta)) return undefined;

    const engine = this.getManagedPlaybackEngine();
    if (engine) {
      let target;

      try {
        target = relativeSeekTarget(engine.getCurrentTime(), delta, engine.getDuration());
      } catch (error) {
        this.debug("[VideoPlayer] managed engine seek skipped:", errorMessage(error));
        return undefined;
      }

      if (target === null) return undefined;

      Promise.resolve()
        .then(() => engine.seek(target))
        .then(() => this.updateMediaSessionPosition({ force: true }))
        .catch((error) => {
          this.debug("[VideoPlayer] managed engine seek skipped:", errorMessage(error));
        });
      return undefined;
    }

    const video = this.getVideo();
    if (video) {
      const target = relativeSeekTarget(video.currentTime, delta, this.getDuration());
      if (target !== null) this.seekNativeTo(target);
    }
    return undefined;
  }

  seekTo(time, { remote = false } = {}) {
    if (this._destroyed) return false;

    const options = { remote: Boolean(remote) };
    if (this.rejectViewerTransportControl(options)) return false;
    if (this.getContentType() === "live") {
      return options.remote ? this.seekLiveTo(time) : false;
    }

    const target = clampSeekTime(Number(time), this.getDuration());
    if (target === null) return undefined;

    const engine = this.getManagedPlaybackEngine();
    if (engine) {
      Promise.resolve()
        .then(() => engine.seek(target))
        .then(() => {
          this.emitPlaybackEvent(this.getRoot(), "seeked");
          this.updateMediaSessionPosition({ force: true });
        })
        .catch((error) => {
          this.debug("[VideoPlayer] managed engine seek skipped:", errorMessage(error));
        });
    } else if (this.getVideo()) {
      this.seekNativeTo(target);
    }

    return undefined;
  }

  seekNativeTo(time) {
    if (this._destroyed) return false;

    const video = this.getVideo();
    const target = Number(time);
    if (!video || this.getContentType() === "live" || !Number.isFinite(target)) return false;

    try {
      this.getNativeBufferingController()?.prepareSeek?.();
      video.currentTime = target;
      return true;
    } catch (error) {
      this.error("[VideoPlayer] native seek failed:", error);
      return false;
    }
  }

  seekLiveTo(time) {
    if (this._destroyed) return false;

    const video = this.getVideo();
    const target = Number(time);
    if (!video || !Number.isFinite(target)) return false;

    try {
      const ranges = video.seekable;
      if (!ranges || ranges.length === 0) return false;

      const rangeIndex = ranges.length - 1;
      const start = ranges.start(rangeIndex);
      const end = ranges.end(rangeIndex);
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return false;

      video.currentTime = Math.max(start, Math.min(end - 0.05, target));
      return true;
    } catch (error) {
      this.error("[VideoPlayer] live seek failed:", error);
      return false;
    }
  }

  setPlaybackRate(rate, { remote = false } = {}) {
    if (this._destroyed) return false;

    const options = { remote: Boolean(remote) };
    if (this.rejectViewerTransportControl(options)) return false;

    const normalizedRate = Number(rate);
    const video = this.getVideo();
    if (!video || !Number.isFinite(normalizedRate) || normalizedRate <= 0) return false;

    if (!this.supportsPlaybackRateControl()) {
      this.getPlayerUiController()?.updateSpeedUI?.(1);
      this.updateMediaSessionPosition({ force: true });
      return false;
    }

    const nativeHls = Boolean(video.canPlayType?.(NATIVE_HLS_MIME_TYPE));
    if (nativeHls && this.isPartyMode() && normalizedRate > 1) {
      video.playbackRate = 1;
      if (!options.remote) this.savePlaybackRate(1);
      this.updateMediaSessionPosition({ force: true });
      if (!options.remote) this.pushEvent("playback_rate_changed", { rate: 1 });
      this.getPlayerUi()?.showNotice?.(
        "Velocidade variável não é suportada com HLS nativo do iOS durante watch party.",
      );
      return true;
    }

    video.playbackRate = normalizedRate;
    if (!options.remote) this.savePlaybackRate(normalizedRate);
    this.updateMediaSessionPosition({ force: true });
    if (!options.remote) {
      this.pushEvent("playback_rate_changed", { rate: normalizedRate });
    }
    return true;
  }

  getCurrentTime() {
    if (this._destroyed) return 0;

    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return nativeEngine.getCurrentTime();

    const engine = this.getManagedPlaybackEngine();
    return engine?.getCurrentTime?.() ?? this.getVideo()?.currentTime ?? 0;
  }

  getDuration() {
    if (this._destroyed) return 0;

    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return nativeEngine.getDuration();

    const engine = this.getManagedPlaybackEngine();
    const duration = engine?.getDuration?.() ?? this.getVideo()?.duration ?? 0;
    const expectedDuration = Number(this.getExpectedDuration());

    if (
      duration > MAX_SANE_DURATION_SECONDS &&
      Number.isFinite(expectedDuration) &&
      expectedDuration > 0
    ) {
      return expectedDuration;
    }

    return duration;
  }

  getPlaybackRate() {
    if (this._destroyed || !this.supportsPlaybackRateControl()) return 1;

    const playbackRate = Number(this.getVideo()?.playbackRate);
    return Number.isFinite(playbackRate) && playbackRate > 0 ? playbackRate : 1;
  }

  isPaused() {
    if (this._destroyed) return true;

    const nativeEngine = this.getNativePlaybackEngine();
    if (nativeEngine) return !nativeEngine.isPlaying();

    const engine = this.getManagedPlaybackEngine();
    if (engine) return !engine.isPlaying();
    return this.getVideo()?.paused ?? true;
  }

  destroy() {
    if (this._destroyed) return;
    this._destroyed = true;
  }

  debug(...args) {
    safely(this.onDebug, ...args);
  }

  error(...args) {
    safely(this.onError, ...args);
  }
}

export function createPlaybackCommandController(options) {
  return new PlaybackCommandController(options);
}
