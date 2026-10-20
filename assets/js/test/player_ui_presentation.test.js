import assert from "node:assert/strict";
import test from "node:test";

import { PlayerUI } from "../player/player_ui.js";

function classListDouble(initial = []) {
  const classes = new Set(initial);

  return {
    add(...names) {
      names.forEach((name) => {
        classes.add(name);
      });
    },
    contains(name) {
      return classes.has(name);
    },
    remove(...names) {
      names.forEach((name) => {
        classes.delete(name);
      });
    },
    toggle(name, force) {
      if (force === undefined) {
        if (classes.has(name)) classes.delete(name);
        else classes.add(name);
      } else if (force) {
        classes.add(name);
      } else {
        classes.delete(name);
      }

      return classes.has(name);
    },
  };
}

function elementDouble(initialClasses = []) {
  const attributes = new Map();

  return {
    classList: classListDouble(initialClasses),
    disabled: false,
    style: {},
    textContent: "",
    title: "",
    value: "",
    getAttribute(name) {
      return attributes.get(name);
    },
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
  };
}

test("renders time and progress from one presentation update", () => {
  const currentTime = elementDouble();
  const duration = elementDouble();
  const progressPlayed = elementDouble();
  const ui = {
    elements: { currentTime, duration, progressPlayed },
    formatTime: PlayerUI.prototype.formatTime,
    updateProgressBar: PlayerUI.prototype.updateProgressBar,
  };

  PlayerUI.prototype.updateTimeUI.call(ui, 75, 120);

  assert.equal(currentTime.textContent, "1:15");
  assert.equal(duration.textContent, "2:00");
  assert.equal(progressPlayed.style.width, "62.5%");
});

test("renders the buffered range containing the current playback position", () => {
  const progressBuffered = elementDouble();
  const buffered = {
    length: 2,
    end(index) {
      return [20, 80][index];
    },
    start(index) {
      return [0, 40][index];
    },
  };
  let bufferAhead = null;
  const ui = {
    elements: { progressBuffered },
    updateBufferHealthIndicator(seconds) {
      bufferAhead = seconds;
    },
  };

  PlayerUI.prototype.updateBufferBar.call(ui, buffered, 100, 45);

  assert.equal(progressBuffered.style.width, "80%");
  assert.equal(bufferAhead, 35);
});

test("coordinates terminal error visibility without leaving loading active", () => {
  const errorContainer = elementDouble(["hidden"]);
  const errorMessage = elementDouble();
  const errorHint = elementDouble(["hidden"]);
  const video = elementDouble();
  let hideLoadingCalls = 0;
  const ui = {
    elements: { errorContainer, errorHint, errorMessage },
    getErrorHint() {
      return "Tente outra fonte.";
    },
    hideLoading() {
      hideLoadingCalls += 1;
    },
    video,
  };

  PlayerUI.prototype.showError.call(ui, "Falha de reprodução");

  assert.equal(hideLoadingCalls, 1);
  assert.equal(errorMessage.textContent, "Falha de reprodução");
  assert.equal(errorHint.textContent, "Tente outra fonte.");
  assert.equal(errorContainer.classList.contains("hidden"), false);
  assert.equal(errorHint.classList.contains("hidden"), false);
  assert.equal(video.classList.contains("hidden"), true);

  PlayerUI.prototype.hideError.call(ui);

  assert.equal(errorContainer.classList.contains("hidden"), true);
  assert.equal(errorHint.classList.contains("hidden"), true);
  assert.equal(errorHint.textContent, "");
  assert.equal(video.classList.contains("hidden"), false);
});

test("shows and hides loading while owning both loading timers", () => {
  const loadingIndicator = elementDouble(["hidden"]);
  const ui = {
    elements: { loadingIndicator },
    hideLoading: PlayerUI.prototype.hideLoading,
    _loadingSafetyTimeout: null,
    _loadingShowTimeout: null,
    video: null,
  };

  PlayerUI.prototype.showLoading.call(ui);

  assert.equal(loadingIndicator.classList.contains("hidden"), false);
  assert.notEqual(ui._loadingSafetyTimeout, null);

  PlayerUI.prototype.hideLoading.call(ui);

  assert.equal(loadingIndicator.classList.contains("hidden"), true);
  assert.equal(ui._loadingSafetyTimeout, null);
  assert.equal(ui._loadingShowTimeout, null);
});

test("coordinates control visibility for playing and native-control modes", () => {
  const controls = elementDouble();
  const topControls = elementDouble();
  const ui = {
    _isPlayingFn: () => true,
    controlsVisible: false,
    elements: { controls, topControls },
    nativeControlsMode: false,
  };

  PlayerUI.prototype.showControls.call(ui);

  assert.equal(ui.controlsVisible, true);
  assert.equal(controls.classList.contains("controls-hidden"), false);
  assert.equal(controls.style.opacity, "1");
  assert.equal(controls.style.pointerEvents, "auto");

  PlayerUI.prototype.hideControls.call(ui);

  assert.equal(ui.controlsVisible, false);
  assert.equal(controls.classList.contains("controls-hidden"), true);
  assert.equal(controls.style.opacity, "0");
  assert.equal(controls.style.pointerEvents, "none");

  ui.nativeControlsMode = true;
  PlayerUI.prototype.hideControls.call(ui);

  assert.equal(ui.controlsVisible, true);
  assert.equal(controls.style.opacity, "1");
  assert.equal(controls.style.pointerEvents, "none");
  assert.equal(topControls.style.pointerEvents, "auto");
});

test("updates quick subtitles toggle button state according to active track (agy-15)", () => {
  const quickSubtitlesBtn = elementDouble();
  const container = {
    querySelector: (selector) =>
      selector === "#quick-subtitles-toggle-btn" ? quickSubtitlesBtn : null,
  };
  const ui = {
    container,
  };

  // Subtitles on (track 0)
  PlayerUI.prototype.updateQuickSubtitlesButton.call(ui, 0);
  assert.equal(quickSubtitlesBtn.textContent, "Desativar");
  assert.equal(quickSubtitlesBtn.getAttribute("aria-label"), "Desativar legendas");
  assert.equal(quickSubtitlesBtn.classList.contains("text-brand"), true);
  assert.equal(quickSubtitlesBtn.classList.contains("text-white/60"), false);

  // Subtitles off (-1)
  PlayerUI.prototype.updateQuickSubtitlesButton.call(ui, -1);
  assert.equal(quickSubtitlesBtn.textContent, "Ativar");
  assert.equal(quickSubtitlesBtn.getAttribute("aria-label"), "Ativar última legenda");
  assert.equal(quickSubtitlesBtn.classList.contains("text-brand"), false);
  assert.equal(quickSubtitlesBtn.classList.contains("text-white/60"), true);
});

test("updates tracks empty state when sections are hidden or visible (agy-15)", () => {
  const tracksEmpty = elementDouble();
  const audioSection = elementDouble(["hidden"]);
  const subtitleSection = elementDouble(["hidden"]);
  const container = {
    querySelector: (selector) => (selector === "#tracks-empty" ? tracksEmpty : null),
  };
  const ui = {
    container,
    elements: { audioSection, subtitleSection },
  };

  // Both hidden -> tracksEmpty is visible (hidden is false)
  PlayerUI.prototype.updateTracksEmptyState.call(ui);
  assert.equal(tracksEmpty.classList.contains("hidden"), false);

  // Subtitle visible -> tracksEmpty is hidden
  subtitleSection.classList.remove("hidden");
  PlayerUI.prototype.updateTracksEmptyState.call(ui);
  assert.equal(tracksEmpty.classList.contains("hidden"), true);

  // Audio visible, subtitle hidden -> tracksEmpty is hidden
  subtitleSection.classList.add("hidden");
  audioSection.classList.remove("hidden");
  PlayerUI.prototype.updateTracksEmptyState.call(ui);
  assert.equal(tracksEmpty.classList.contains("hidden"), true);
});
