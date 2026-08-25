const REQUIRED_UI_METHODS = Object.freeze([
  "clearHideControlsTimeout",
  "destroy",
  "hideError",
  "hideLoading",
  "scheduleHideControls",
  "setIsPlayingFn",
  "setNativeControlsMode",
  "setPiPAvailable",
  "showControls",
  "showError",
  "showLoading",
  "toggleControlsVisibility",
  "updateBufferBar",
  "updateFullscreenUI",
  "updatePiPUI",
  "updatePlayPauseUI",
  "updateSpeedUI",
  "updateTimeUI",
]);

function assertFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`PlayerUiController requires ${name}()`);
  }

  return value;
}

function assertUi(ui) {
  if (!ui || typeof ui !== "object") {
    throw new TypeError("PlayerUiController requires a PlayerUI instance");
  }

  for (const method of REQUIRED_UI_METHODS) {
    assertFunction(ui[method], `ui.${method}`);
  }

  return ui;
}

function reportOptionalFailure(onError, operation, error) {
  try {
    onError?.(operation, error);
  } catch (_error) {
    // Presentation diagnostics must never replace the original UI operation.
  }
}

export class PlayerUiController {
  constructor({
    emit,
    getBufferState,
    getCurrentTime,
    getDuration,
    initialPiPActive = false,
    isPiPSupported,
    isPlaying,
    onError = null,
    onPiPStateChange = null,
    ui,
    updateMediaSessionPosition,
  }) {
    this.ui = assertUi(ui);
    this.emit = assertFunction(emit, "emit");
    this.getBufferState = assertFunction(getBufferState, "getBufferState");
    this.getCurrentTime = assertFunction(getCurrentTime, "getCurrentTime");
    this.getDuration = assertFunction(getDuration, "getDuration");
    this.isPiPSupported = assertFunction(isPiPSupported, "isPiPSupported");
    this.isPlaying = assertFunction(isPlaying, "isPlaying");
    this.updateMediaSessionPosition = assertFunction(
      updateMediaSessionPosition,
      "updateMediaSessionPosition",
    );

    if (onError !== null) assertFunction(onError, "onError");
    if (onPiPStateChange !== null) {
      assertFunction(onPiPStateChange, "onPiPStateChange");
    }

    this.onError = onError;
    this.onPiPStateChange = onPiPStateChange;
    this._destroyed = false;
    this._pipActive = Boolean(initialPiPActive);
    this._pipAvailable = false;

    this.ui.setIsPlayingFn(() => !this._destroyed && Boolean(this.isPlaying()));
  }

  get controlsVisible() {
    return !this._destroyed && Boolean(this.ui.controlsVisible);
  }

  get destroyed() {
    return this._destroyed;
  }

  get pipActive() {
    return this._pipActive;
  }

  get pipAvailable() {
    return this._pipAvailable;
  }

  updateTime() {
    if (this._destroyed) return null;

    const currentTime = this.getCurrentTime();
    const duration = this.getDuration();
    this.ui.updateTimeUI(currentTime, duration);
    this.updateMediaSessionPosition();

    return Object.freeze({ currentTime, duration });
  }

  updateBuffer() {
    if (this._destroyed) return null;

    const state = this.getBufferState();
    if (!state?.buffered) return null;

    const snapshot = Object.freeze({
      buffered: state.buffered,
      currentTime: state.currentTime,
      duration: state.duration,
    });

    this.ui.updateBufferBar(snapshot.buffered, snapshot.duration, snapshot.currentTime);
    return snapshot;
  }

  updatePlayPauseUI(paused) {
    if (this._destroyed) return;
    this.ui.updatePlayPauseUI(paused);
  }

  updateSpeedUI(rate) {
    if (this._destroyed) return;
    this.ui.updateSpeedUI(rate);
  }

  updateFullscreenUI(active) {
    if (this._destroyed) return;
    this.ui.updateFullscreenUI(Boolean(active));
  }

  bindRetry(handler, listen) {
    if (this._destroyed) return false;

    assertFunction(handler, "retry handler");
    assertFunction(listen, "listen");

    const retryButton = this.ui.elements?.retryBtn;
    if (!retryButton) return false;

    listen(retryButton, "click", handler);
    return true;
  }

  showLoading() {
    if (this._destroyed) return;
    this.ui.showLoading();
  }

  hideLoading() {
    if (this._destroyed) return;
    this.ui.hideLoading();
  }

  showError(message, hint = null) {
    if (this._destroyed) return;
    this.ui.showError(message, hint);
  }

  hideError() {
    if (this._destroyed) return;
    this.ui.hideError();
  }

  showRecovery() {
    if (this._destroyed) return;
    this.ui.hideError();
    this.ui.showLoading();
  }

  setPiPState(active) {
    if (this._destroyed) return false;

    const nextState = Boolean(active);
    const changed = this._pipActive !== nextState;
    this._pipActive = nextState;
    this.ui.updatePiPUI(nextState);

    if (changed) {
      this.onPiPStateChange?.(nextState);

      try {
        this.emit("pip_toggled", { active: nextState });
      } catch (error) {
        reportOptionalFailure(this.onError, "emit_pip_toggled", error);
      }
    }

    return changed;
  }

  syncPiPAvailability() {
    if (this._destroyed) return false;

    const available = Boolean(this.isPiPSupported());
    this._pipAvailable = available;
    this.ui.setPiPAvailable(available);
    return available;
  }

  disablePiP() {
    if (this._destroyed) return;

    this.setPiPState(false);
    this._pipAvailable = false;
    this.ui.setPiPAvailable(false);
  }

  cancelControlsAutoHide() {
    if (this._destroyed) return;
    this.ui.clearHideControlsTimeout();
  }

  scheduleControlsAutoHide() {
    if (this._destroyed) return;
    this.ui.scheduleHideControls();
  }

  toggleControlsVisibility() {
    if (this._destroyed) return false;

    this.ui.toggleControlsVisibility();
    return this.controlsVisible;
  }

  revealControls({ autoHide = true } = {}) {
    if (this._destroyed) return;

    this.ui.showControls();
    if (autoHide) this.ui.scheduleHideControls();
  }

  keepControlsVisible() {
    if (this._destroyed) return;

    this.ui.showControls();
    this.ui.clearHideControlsTimeout();
  }

  setNativeControlsMode(enabled) {
    if (this._destroyed) return;
    this.ui.setNativeControlsMode(Boolean(enabled));
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this.ui.destroy();
    return true;
  }
}

export function createPlayerUiController(options) {
  return new PlayerUiController(options);
}
