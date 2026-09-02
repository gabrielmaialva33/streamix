import { PLAYBACK_STATE } from "./engine_contract.js";
import { assertActivationHost } from "./playback_engine_activation.js";

export const MEDIA_EVENT_BINDINGS_HOST_METHODS = Object.freeze([
  "emergencyStopPlayback",
  "emitPlaybackEvent",
  "flushPlaybackMetrics",
  "getBufferingController",
  "getIosPwaController",
  "getUiController",
  "getWatchPartyPolicy",
  "handleNativeVolumeChange",
  "handlePlaybackEnded",
  "handlePlaybackPaused",
  "handlePlaybackStarted",
  "isIosPwaMode",
  "isVodContent",
  "observePlaybackState",
  "reportDuration",
  "reportProgress",
  "setPlaybackRate",
  "setVolume",
  "setWatchPartySyncHold",
  "toggleAVPlayerPreference",
  "toggleFullscreen",
  "toggleMute",
  "togglePiP",
  "togglePlayPause",
  "updateBufferBar",
  "updateTimeUI",
  "usesNativePlaybackEvents",
]);

function assertLifecycle(lifecycle) {
  if (
    !lifecycle ||
    typeof lifecycle.listen !== "function" ||
    typeof lifecycle.listenOptional !== "function"
  ) {
    throw new TypeError("MediaEventBindings requires a lifecycle scope");
  }
  return lifecycle;
}

/**
 * Wires the player root, the media element, and the page lifecycle to the
 * player hook through an explicit host.
 *
 * The bindings translate DOM/browser events into host commands: custom
 * control events and the volume slider, native <video> events (UI updates,
 * buffering, playback-bridge notifications, VOD progress), and the
 * visibility/pagehide lifecycle used by the iOS PWA controller. Listener
 * ownership stays with the injected lifecycle scope, so tearing down the
 * scope removes every binding.
 */
export class MediaEventBindings {
  constructor({
    host,
    lifecycle,
    root,
    video,
    documentRef = globalThis.document,
    windowRef = globalThis.window,
    queueTask = (task) => queueMicrotask(task),
  } = {}) {
    this.host = assertActivationHost(host, MEDIA_EVENT_BINDINGS_HOST_METHODS, "MediaEventBindings");
    this.lifecycle = assertLifecycle(lifecycle);
    this.root = root;
    this.video = video;
    this.documentRef = documentRef;
    this.windowRef = windowRef;
    this.queueTask = queueTask;
  }

  bindAll() {
    this.bindControlEvents();
    this.bindMediaEvents();
    this.bindPageLifecycle();
  }

  bindControlEvents() {
    const { lifecycle, root } = this;

    lifecycle.listen(root, "player:toggle-play", () => this.host.togglePlayPause());
    lifecycle.listen(root, "player:toggle-mute", () => this.host.toggleMute());
    lifecycle.listen(root, "player:toggle-fullscreen", () => this.host.toggleFullscreen());
    lifecycle.listen(root, "player:toggle-pip", () => this.host.togglePiP());
    lifecycle.listen(root, "player:set-speed", (event) => {
      const speed = Number.parseFloat(event.detail?.speed || 1);
      this.host.setPlaybackRate(speed);
    });
    lifecycle.listen(root, "player:toggle-avplayer", () => this.host.toggleAVPlayerPreference());

    const volumeSlider = root.querySelector("#volume-slider");
    if (volumeSlider) {
      lifecycle.listen(volumeSlider, "input", (event) => {
        const volume = Number.parseInt(event.target.value, 10) / 100;
        this.host.setVolume(volume);
      });
    }
  }

  bindMediaEvents() {
    this.lifecycle.listenOptional(this.video, "play", () => {
      if (this.host.getWatchPartyPolicy()?.shouldReapplyHoldOnPlay()) {
        this.queueTask(() => this.host.setWatchPartySyncHold(true));
        return;
      }

      this.host.getUiController().updatePlayPauseUI(false);
      this.host.getIosPwaController().persist({
        userPaused: false,
        wasPlaying: true,
        reason: "play",
      });
      if (this.host.usesNativePlaybackEvents()) {
        this.host.emitPlaybackEvent("play");
      }
    });
    this.lifecycle.listenOptional(this.video, "pause", () => {
      const iosPwa = this.host.getIosPwaController();
      this.host.getUiController().updatePlayPauseUI(true);
      this.host.getBufferingController().handlePause();
      iosPwa.persist({
        userPaused: iosPwa.pauseWasUserInitiated(),
        wasPlaying: false,
        reason: "pause",
      });
      if (this.host.usesNativePlaybackEvents()) {
        this.host.handlePlaybackPaused();
        this.host.emitPlaybackEvent("pause");
      }
    });
    this.lifecycle.listenOptional(this.video, "ended", () => {
      if (this.host.usesNativePlaybackEvents()) this.host.handlePlaybackEnded();
      this.host.flushPlaybackMetrics("completed");
    });
    this.lifecycle.listenOptional(this.video, "volumechange", () =>
      this.host.handleNativeVolumeChange(),
    );
    this.lifecycle.listenOptional(this.video, "timeupdate", () => {
      this.host.updateTimeUI();
      this.host.getBufferingController().handleTimeUpdate();
    });
    this.lifecycle.listenOptional(this.video, "loadedmetadata", () => this.host.updateTimeUI());
    this.lifecycle.listenOptional(this.video, "ratechange", () =>
      this.host.getUiController().updateSpeedUI(this.video.playbackRate),
    );
    this.lifecycle.listenOptional(this.video, "progress", () => {
      this.host.updateBufferBar();
      this.host.getBufferingController().handleProgress();
    });

    // Progress tracking for VOD
    if (this.host.isVodContent()) {
      this.lifecycle.listenOptional(this.video, "timeupdate", () => this.host.reportProgress());
      this.lifecycle.listenOptional(this.video, "durationchange", () => {
        const { duration } = this.video;
        if (duration && Number.isFinite(duration)) {
          this.host.reportDuration(Math.floor(duration));
        }
      });
    }

    this.lifecycle.listenOptional(this.video, "seeking", () =>
      this.host.getBufferingController().handleSeeking(),
    );
    this.lifecycle.listenOptional(this.video, "seeked", () => {
      this.host.getBufferingController().handleSeeked();
      if (this.host.usesNativePlaybackEvents()) this.host.emitPlaybackEvent("seeked");
    });

    // Buffer health monitoring with debounce to prevent flickering
    this.lifecycle.listenOptional(this.video, "waiting", () => {
      this.host.observePlaybackState(PLAYBACK_STATE.STALLED, "media_waiting");
      this.host.getBufferingController().handleWaiting();
    });
    this.lifecycle.listenOptional(this.video, "playing", () => {
      if (this.host.usesNativePlaybackEvents()) {
        this.host.handlePlaybackStarted();
      } else {
        this.host.observePlaybackState(PLAYBACK_STATE.PLAYING, "media_playing");
      }
      this.host.getBufferingController().handlePlaying();
    });

    // Also hide loading on canplaythrough (video exits buffering during playback)
    // The "playing" event does not fire when video exits buffering if already playing
    this.lifecycle.listenOptional(this.video, "canplaythrough", () =>
      this.host.getBufferingController().handleCanPlayThrough(),
    );
  }

  bindPageLifecycle() {
    this.lifecycle.listen(this.documentRef, "visibilitychange", () =>
      this.host.getIosPwaController().handleVisibilityChange(),
    );
    this.lifecycle.listen(this.windowRef, "pageshow", () =>
      this.host.getIosPwaController().resume(),
    );

    const onPageTeardown = (event) => {
      this.host.getIosPwaController().handlePageHide(event);
      if (this.host.isIosPwaMode() && event?.persisted) return;
      this.host.flushPlaybackMetrics("cancelled");
      this.host.emergencyStopPlayback();
    };
    this.lifecycle.listen(this.windowRef, "pagehide", onPageTeardown, { capture: true });
    this.lifecycle.listen(this.windowRef, "beforeunload", onPageTeardown, { capture: true });
  }
}

export function createMediaEventBindings(options) {
  return new MediaEventBindings(options);
}
