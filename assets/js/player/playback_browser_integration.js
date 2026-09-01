import { KeyboardManager } from "../core/keyboard_manager.js";
import { LifecycleScope } from "./lifecycle_scope.js";
import { createMediaSessionController } from "./media_session_controller.js";
import {
  exitPictureInPicture,
  isPictureInPictureSupported,
  togglePictureInPicture,
} from "./pip_controller.js";
import { isAppleTouchDevice } from "./playback_environment.js";
import { createScreenWakeLockController } from "./screen_wake_lock_controller.js";

function requiredFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlaybackBrowserIntegration requires ${name}()`);
  }

  return value;
}

function requiredObject(value, name) {
  if (!value || typeof value !== "object") {
    throw new TypeError(`PlaybackBrowserIntegration requires ${name}`);
  }

  return value;
}

function assertCommands(commands) {
  requiredObject(commands, "commands");

  for (const method of [
    "adjustVolume",
    "getCurrentTime",
    "getDuration",
    "getPlaybackRate",
    "isPaused",
    "seek",
    "seekTo",
    "setPlaybackRate",
    "toggleMute",
    "togglePlayPause",
  ]) {
    requiredFunction(commands[method], `commands.${method}`);
  }

  return commands;
}

const defaultDependencies = {
  createKeyboardManager: (options) => new KeyboardManager(options),
  createMediaSessionController,
  createScreenWakeLockController,
  exitPictureInPicture,
  isAppleTouchDevice,
  isPictureInPictureSupported,
  togglePictureInPicture,
};

/**
 * Composes browser-owned playback APIs around the engine-agnostic command
 * controller. Media engines and their lifecycle deliberately stay outside.
 */
export class PlaybackBrowserIntegration {
  constructor({
    commands,
    documentRef = globalThis.document,
    dependencies = {},
    emit,
    getCanvasPlaybackActive,
    getContentType,
    getMuted,
    isPlayerDestroyed,
    metadata = {},
    navigatorRef = globalThis.navigator,
    onError = () => {},
    presentation,
    root,
    video,
    windowRef = globalThis.window,
  } = {}) {
    this.commands = assertCommands(commands);
    this.documentRef = documentRef;
    this.deps = { ...defaultDependencies, ...dependencies };
    this.emit = requiredFunction(emit, "emit");
    this.getCanvasPlaybackActive = requiredFunction(
      getCanvasPlaybackActive,
      "getCanvasPlaybackActive",
    );
    this.getContentType = requiredFunction(getContentType, "getContentType");
    this.getMuted = requiredFunction(getMuted, "getMuted");
    this.isPlayerDestroyed = requiredFunction(isPlayerDestroyed, "isPlayerDestroyed");
    this.metadata = metadata;
    this.navigatorRef = navigatorRef;
    this.onError = requiredFunction(onError, "onError");
    this.presentation = requiredObject(presentation, "presentation");
    this.root = requiredObject(root, "root");
    this.video = video;
    this.windowRef = windowRef;

    this.keyboardManager = null;
    this.mediaSessionController = null;
    this.screenWakeLockController = null;
    this.started = false;
    this.destroyed = false;
    this.lifecycle = new LifecycleScope({
      onDisposeError: (error) => this.reportError("listener-cleanup", error),
    });
  }

  start() {
    if (this.destroyed || this.started) return false;
    this.started = true;

    const updateFullscreenState = () =>
      this.presentation.updateFullscreenUI(Boolean(this.documentRef?.fullscreenElement));
    this.lifecycle.listenOptional(this.documentRef, "fullscreenchange", updateFullscreenState);
    this.lifecycle.listenOptional(
      this.documentRef,
      "webkitfullscreenchange",
      updateFullscreenState,
    );

    this.lifecycle.listenOptional(this.video, "enterpictureinpicture", () => {
      this.setPiPState(true);
    });
    this.lifecycle.listenOptional(this.video, "leavepictureinpicture", () => {
      this.setPiPState(false);
    });
    this.lifecycle.listenOptional(this.video, "webkitpresentationmodechanged", () => {
      this.setPiPState(this.video?.webkitPresentationMode === "picture-in-picture");
    });

    return true;
  }

  setupKeyboardShortcuts() {
    if (this.destroyed) return false;

    if (this.keyboardManager) {
      this.keyboardManager.setContentType?.(this.getContentType());
      this.keyboardManager.start?.();
      return true;
    }

    this.keyboardManager = this.deps.createKeyboardManager({
      contentType: this.getContentType(),
      documentRef: this.documentRef,
      actions: {
        togglePlayPause: () => this.commands.togglePlayPause(),
        toggleMute: () => this.commands.toggleMute(),
        toggleFullscreen: () => this.toggleFullscreen(),
        togglePiP: () => this.togglePiP(),
        adjustVolume: (delta) => this.commands.adjustVolume(delta),
        seek: (seconds) => this.commands.seek(seconds),
        seekTo: (time) => this.commands.seekTo(time),
        setPlaybackRate: (rate) => this.commands.setPlaybackRate(rate),
        getDuration: () => this.commands.getDuration(),
        isPaused: () => this.commands.isPaused(),
        isMuted: () => this.getMuted(),
        isPiPSupported: () => this.isPiPSupported(),
        getPlaybackRate: () => this.commands.getPlaybackRate(),
      },
    });
    this.keyboardManager.start();
    return true;
  }

  toggleFullscreen() {
    if (this.destroyed) return false;

    if (this.documentRef?.fullscreenElement) {
      return this.documentRef.exitFullscreen?.();
    }

    if (this.video?.webkitDisplayingFullscreen) {
      return this.video.webkitExitFullscreen?.();
    }

    if (this.deps.isAppleTouchDevice(this.navigatorRef) && this.video?.webkitEnterFullscreen) {
      return this.video.webkitEnterFullscreen();
    }

    return this.root.requestFullscreen?.() || this.video?.requestFullscreen?.();
  }

  async togglePiP() {
    if (this.destroyed || !this.isPiPSupported()) return;

    try {
      const active = await this.deps.togglePictureInPicture({
        documentRef: this.documentRef,
        video: this.video,
      });
      this.setPiPState(active);
    } catch (error) {
      this.reportError("picture-in-picture", error);
      this.emit("pip_error", { message: error?.message || String(error) });
    }
  }

  isPiPSupported() {
    if (this.destroyed) return false;

    return this.deps.isPictureInPictureSupported({
      canvasPlaybackActive: this.getCanvasPlaybackActive(),
      documentRef: this.documentRef,
      video: this.video,
    });
  }

  setPiPState(active) {
    if (this.destroyed) return false;
    return this.presentation.setPiPState(active) ?? false;
  }

  syncPiPAvailability() {
    if (this.destroyed) return false;
    return this.presentation.syncPiPAvailability() ?? false;
  }

  disablePiPForCanvasPlayback() {
    if (this.destroyed) return;

    this.presentation.disablePiP();
    void this.deps
      .exitPictureInPicture({ documentRef: this.documentRef, video: this.video })
      .catch(() => {});
  }

  setupPlaybackSystemIntegration() {
    if (this.destroyed) return false;

    if (!this.screenWakeLockController) {
      this.screenWakeLockController = this.deps.createScreenWakeLockController({
        documentRef: this.documentRef,
        navigatorRef: this.navigatorRef,
        onError: (operation, error) => this.reportError(`screen-wake-lock:${operation}`, error),
      });
    }

    if (!this.mediaSessionController) {
      this.mediaSessionController = this.deps.createMediaSessionController({
        navigatorRef: this.navigatorRef,
        windowRef: this.windowRef,
        metadata: this.metadata,
        actions: {
          play: () => {
            if (this.commands.isPaused()) return this.commands.togglePlayPause();
            return undefined;
          },
          pause: () => {
            if (!this.commands.isPaused()) return this.commands.togglePlayPause();
            return undefined;
          },
          seekbackward: (event) => this.commands.seek(-(event.seekOffset || 10)),
          seekforward: (event) => this.commands.seek(event.seekOffset || 10),
          seekto: (event) => {
            if (typeof event.seekTime === "number") this.commands.seekTo(event.seekTime);
          },
        },
        onError: (operation, error) => this.reportError(`media-session:${operation}`, error),
      });
      this.mediaSessionController.setup();
    }

    this.setPlaybackSystemState("none");
    return true;
  }

  setPlaybackSystemState(state) {
    if (this.destroyed || (this.isPlayerDestroyed() && state !== "none")) return false;

    this.mediaSessionController?.setPlaybackState(state);
    void this.screenWakeLockController?.setPlaybackActive(state === "playing");

    if (state !== "none") this.updateMediaSessionPosition({ force: true });
    return true;
  }

  updateMediaSessionPosition({ force = false } = {}) {
    if (this.destroyed || !this.mediaSessionController) return false;

    if (this.getContentType() !== "vod") {
      if (force) return this.mediaSessionController.clearPosition();
      return false;
    }

    return this.mediaSessionController.updatePosition({
      duration: this.commands.getDuration(),
      position: this.commands.getCurrentTime(),
      playbackRate: this.commands.getPlaybackRate(),
      force,
    });
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.lifecycle.dispose();
    this.keyboardManager?.destroy();
    this.keyboardManager = null;
    this.mediaSessionController?.destroy();
    this.mediaSessionController = null;

    const wakeLockController = this.screenWakeLockController;
    this.screenWakeLockController = null;
    void wakeLockController?.destroy();
  }

  reportError(operation, error) {
    try {
      this.onError(operation, error);
    } catch {
      // Browser integration diagnostics must never interrupt playback.
    }
  }
}

export function createPlaybackBrowserIntegration(options) {
  return new PlaybackBrowserIntegration(options);
}
