import assert from "node:assert/strict";
import test from "node:test";

import { createPlayerUiController } from "../player/player_ui_controller.js";

function createHarness(overrides = {}) {
  const calls = [];
  const ui = {
    controlsVisible: false,
    elements: { retryBtn: { id: "retry" } },
    clearHideControlsTimeout() {
      calls.push(["clearHideControlsTimeout"]);
    },
    destroy() {
      calls.push(["destroy"]);
    },
    hideError() {
      calls.push(["hideError"]);
    },
    hideLoading() {
      calls.push(["hideLoading"]);
    },
    scheduleHideControls() {
      calls.push(["scheduleHideControls"]);
    },
    setIsPlayingFn(callback) {
      this.isPlaying = callback;
      calls.push(["setIsPlayingFn"]);
    },
    setNativeControlsMode(enabled) {
      calls.push(["setNativeControlsMode", enabled]);
    },
    setPiPAvailable(available) {
      calls.push(["setPiPAvailable", available]);
    },
    showControls() {
      this.controlsVisible = true;
      calls.push(["showControls"]);
    },
    showError(message, hint) {
      calls.push(["showError", message, hint]);
    },
    showLoading() {
      calls.push(["showLoading"]);
    },
    toggleControlsVisibility() {
      this.controlsVisible = !this.controlsVisible;
      calls.push(["toggleControlsVisibility"]);
    },
    updateBufferBar(buffered, duration, currentTime) {
      calls.push(["updateBufferBar", buffered, duration, currentTime]);
    },
    updateFullscreenUI(active) {
      calls.push(["updateFullscreenUI", active]);
    },
    updatePiPUI(active) {
      calls.push(["updatePiPUI", active]);
    },
    updatePlayPauseUI(paused) {
      calls.push(["updatePlayPauseUI", paused]);
    },
    updateSpeedUI(rate) {
      calls.push(["updateSpeedUI", rate]);
    },
    updateTimeUI(currentTime, duration) {
      calls.push(["updateTimeUI", currentTime, duration]);
    },
    ...overrides.ui,
  };

  const emitted = [];
  const errors = [];
  const pipChanges = [];
  const buffered = { length: 1 };
  let playing = true;
  let pipSupported = true;
  let mediaSessionUpdates = 0;

  const controller = createPlayerUiController({
    emit(event, payload) {
      emitted.push([event, payload]);
    },
    getBufferState: () => ({ buffered, currentTime: 25, duration: 100 }),
    getCurrentTime: () => 25,
    getDuration: () => 100,
    initialPiPActive: false,
    isPiPSupported: () => pipSupported,
    isPlaying: () => playing,
    onError(operation, error) {
      errors.push([operation, error]);
    },
    onPiPStateChange(active) {
      pipChanges.push(active);
    },
    ui,
    updateMediaSessionPosition() {
      mediaSessionUpdates += 1;
    },
    ...overrides.controller,
  });

  return {
    buffered,
    calls,
    controller,
    emitted,
    errors,
    get mediaSessionUpdates() {
      return mediaSessionUpdates;
    },
    pipChanges,
    setPiPSupported(value) {
      pipSupported = value;
    },
    setPlaying(value) {
      playing = value;
    },
    ui,
  };
}

test("validates the presentation contract", () => {
  assert.throws(
    () =>
      createPlayerUiController({
        emit() {},
        getBufferState() {},
        getCurrentTime() {},
        getDuration() {},
        isPiPSupported() {},
        isPlaying() {},
        ui: {},
        updateMediaSessionPosition() {},
      }),
    /ui\.clearHideControlsTimeout/,
  );
});

test("wires active playback state into PlayerUI", () => {
  const harness = createHarness();

  assert.equal(harness.ui.isPlaying(), true);
  harness.setPlaying(false);
  assert.equal(harness.ui.isPlaying(), false);

  harness.controller.destroy();
  assert.equal(harness.ui.isPlaying(), false);
});

test("coordinates time, buffer, and media-session presentation", () => {
  const harness = createHarness();

  assert.deepEqual(harness.controller.updateTime(), { currentTime: 25, duration: 100 });
  assert.equal(harness.mediaSessionUpdates, 1);
  assert.deepEqual(harness.calls.at(-1), ["updateTimeUI", 25, 100]);

  const snapshot = harness.controller.updateBuffer();
  assert.equal(snapshot.buffered, harness.buffered);
  assert.equal(snapshot.currentTime, 25);
  assert.equal(snapshot.duration, 100);
  assert.deepEqual(harness.calls.at(-1), ["updateBufferBar", harness.buffered, 100, 25]);
});

test("owns playback speed and fullscreen presentation", () => {
  const harness = createHarness();

  harness.controller.updateSpeedUI(1.5);
  harness.controller.updateFullscreenUI(1);

  assert.deepEqual(harness.calls.slice(-2), [
    ["updateSpeedUI", 1.5],
    ["updateFullscreenUI", true],
  ]);
});

test("owns retry binding without exposing PlayerUI internals to the hook", () => {
  const harness = createHarness();
  const listeners = [];
  let retries = 0;

  assert.equal(
    harness.controller.bindRetry(
      () => {
        retries += 1;
      },
      (target, event, handler) => listeners.push({ event, handler, target }),
    ),
    true,
  );

  assert.equal(listeners.length, 1);
  assert.equal(listeners[0].target, harness.ui.elements.retryBtn);
  assert.equal(listeners[0].event, "click");
  listeners[0].handler();
  assert.equal(retries, 1);
});

test("skips retry binding when the presentation has no retry action", () => {
  const harness = createHarness({ ui: { elements: {} } });

  assert.equal(
    harness.controller.bindRetry(
      () => {},
      () => assert.fail("listen must not be called without a retry button"),
    ),
    false,
  );
});

test("composes recovery and terminal error presentation", () => {
  const harness = createHarness();

  harness.controller.showRecovery();
  assert.deepEqual(harness.calls.slice(-2), [["hideError"], ["showLoading"]]);

  harness.controller.showError("Falha", "Tente outra fonte");
  harness.controller.hideError();
  harness.controller.hideLoading();

  assert.deepEqual(harness.calls.slice(-3), [
    ["showError", "Falha", "Tente outra fonte"],
    ["hideError"],
    ["hideLoading"],
  ]);
});

test("owns PiP availability and emits state changes once", () => {
  const harness = createHarness();

  assert.equal(harness.controller.syncPiPAvailability(), true);
  assert.equal(harness.controller.pipAvailable, true);

  assert.equal(harness.controller.setPiPState(true), true);
  assert.equal(harness.controller.setPiPState(true), false);
  assert.equal(harness.controller.pipActive, true);
  assert.deepEqual(harness.pipChanges, [true]);
  assert.deepEqual(harness.emitted, [["pip_toggled", { active: true }]]);

  harness.setPiPSupported(false);
  assert.equal(harness.controller.syncPiPAvailability(), false);
  harness.controller.disablePiP();

  assert.equal(harness.controller.pipAvailable, false);
  assert.equal(harness.controller.pipActive, false);
  assert.deepEqual(harness.pipChanges, [true, false]);
  assert.deepEqual(harness.emitted.at(-1), ["pip_toggled", { active: false }]);
});

test("contains optional PiP telemetry failures", () => {
  const expected = new Error("transport disconnected");
  const harness = createHarness({
    controller: {
      emit() {
        throw expected;
      },
    },
  });

  assert.equal(harness.controller.setPiPState(true), true);
  assert.deepEqual(harness.errors, [["emit_pip_toggled", expected]]);
  assert.equal(harness.controller.pipActive, true);
});

test("coordinates control visibility and native-controls mode", () => {
  const harness = createHarness();

  assert.equal(harness.controller.controlsVisible, false);
  harness.controller.revealControls();
  assert.equal(harness.controller.controlsVisible, true);
  assert.deepEqual(harness.calls.slice(-2), [["showControls"], ["scheduleHideControls"]]);

  harness.controller.keepControlsVisible();
  assert.deepEqual(harness.calls.slice(-2), [["showControls"], ["clearHideControlsTimeout"]]);

  harness.controller.cancelControlsAutoHide();
  harness.controller.scheduleControlsAutoHide();
  assert.equal(harness.controller.toggleControlsVisibility(), false);
  assert.deepEqual(harness.calls.slice(-3), [
    ["clearHideControlsTimeout"],
    ["scheduleHideControls"],
    ["toggleControlsVisibility"],
  ]);

  harness.controller.setNativeControlsMode(true);
  harness.controller.updatePlayPauseUI(false);
  assert.deepEqual(harness.calls.slice(-2), [
    ["setNativeControlsMode", true],
    ["updatePlayPauseUI", false],
  ]);
});

test("destroy is idempotent and blocks later presentation writes", () => {
  const harness = createHarness();

  assert.equal(harness.controller.destroy(), true);
  assert.equal(harness.controller.destroy(), false);
  harness.controller.showLoading();
  harness.controller.updateTime();

  assert.equal(harness.calls.filter(([name]) => name === "destroy").length, 1);
  assert.equal(harness.calls.filter(([name]) => name === "showLoading").length, 0);
  assert.equal(harness.calls.filter(([name]) => name === "updateTimeUI").length, 0);
});
