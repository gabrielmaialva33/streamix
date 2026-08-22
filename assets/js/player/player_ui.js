/**
 * Player UI Manager
 *
 * Handles UI updates for the video player.
 * HTML structure is in HEEX templates - this only manages state/visibility.
 */

import { createFocusTrap } from "../core/focus_trap.js";
import { bufferDiagnosticsEnabled } from "./player_diagnostics_visibility.js";

/**
 * PlayerUI class - manages UI state updates
 */
export class PlayerUI {
  constructor(container) {
    this.container = container;
    this.video = container.querySelector("video");
    this.focusTraps = new Map();
    // Hook can override this to report the active player's state
    // (e.g. AVPlayer keeps the native <video> paused while its
    // own canvas plays; without this hook, auto-hide treats the
    // player as paused forever and controls never fade).
    this._isPlayingFn = () => this.video && !this.video.paused;

    // Cache DOM elements
    this.elements = {
      // Loading/Error
      loadingIndicator: container.querySelector("#loading-indicator"),
      errorContainer: container.querySelector("#error-container"),
      errorMessage: container.querySelector(".error-message"),
      errorHint: container.querySelector(".error-hint"),
      retryBtn: container.querySelector(".retry-btn"),

      // Play/Pause
      playIcon: container.querySelector(".play-icon"),
      pauseIcon: container.querySelector(".pause-icon"),

      // Volume
      muteButton: container.querySelector("#mute-btn"),
      volumeOnIcon: container.querySelector(".volume-on-icon"),
      volumeOffIcon: container.querySelector(".volume-off-icon"),
      volumeSlider: container.querySelector("#volume-slider"),

      // Time
      currentTime: container.querySelector("#current-time"),
      duration: container.querySelector("#duration"),

      // Progress
      progressPlayed: container.querySelector("#progress-played"),
      progressBuffered: container.querySelector("#progress-buffered"),
      progressContainer: container.querySelector("#progress-container"),

      // Speed
      speedLabel: container.querySelector("#speed-label"),

      // Fullscreen
      expandIcon: container.querySelector(".expand-icon"),
      collapseIcon: container.querySelector(".collapse-icon"),

      // Picture-in-Picture
      pipButton: container.querySelector("#pip-btn"),

      // Controls container
      controls: container.querySelector("#player-controls"),
      topControls: container.querySelector("#player-top-controls"),
      bottomControls: container.querySelector("#player-bottom-controls"),

      // Quality/Audio/Subtitle containers
      qualityOptions: container.querySelector("#quality-options"),
      audioSection: container.querySelector("#audio-section"),
      audioOptions: container.querySelector("#audio-options"),
      subtitleSection: container.querySelector("#subtitle-section"),
      subtitleOptions: container.querySelector("#subtitle-options"),
    };

    // Controls visibility state
    this.controlsVisible = true;
    this.controlsTimeout = null;
    this.isTouchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;
    this.elements.controls?.classList.toggle("touch-device", this.isTouchDevice);
    this.nativeControlsMode = false;

    // Setup menu focus traps
    this.setupMenuFocusTraps();
  }

  // ============================================
  // Menu Focus Traps (Accessibility)
  // ============================================

  setupMenuFocusTraps() {
    // Speed menu
    const speedMenu = this.container.querySelector("#speed-menu");
    const speedBtn = this.container.querySelector("#speed-btn");
    if (speedMenu && speedBtn) {
      this.setupMenuFocusTrap(speedMenu, speedBtn, "speed");
    }

    // Settings menu
    const settingsMenu = this.container.querySelector("#settings-menu");
    const settingsBtn = this.container.querySelector("#settings-btn");
    if (settingsMenu && settingsBtn) {
      this.setupMenuFocusTrap(settingsMenu, settingsBtn, "settings");
    }
  }

  setupMenuFocusTrap(menu, triggerBtn, name) {
    const focusTrap = createFocusTrap(menu, {
      returnFocusTo: triggerBtn,
      onEscape: () => {
        menu.classList.add("hidden");
        triggerBtn.setAttribute("aria-expanded", "false");
      },
    });

    this.focusTraps.set(name, focusTrap);

    // Use MutationObserver to detect when menu visibility changes
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.attributeName === "class") {
          const isHidden = menu.classList.contains("hidden");
          if (isHidden) {
            focusTrap.deactivate();
            triggerBtn.setAttribute("aria-expanded", "false");
          } else {
            focusTrap.activate();
            triggerBtn.setAttribute("aria-expanded", "true");
          }
        }
      }
    });

    observer.observe(menu, { attributes: true, attributeFilter: ["class"] });

    // Store observer for cleanup
    if (!this._menuObservers) {
      this._menuObservers = [];
    }
    this._menuObservers.push(observer);
  }

  // ============================================
  // Loading/Error States
  // ============================================

  showLoading() {
    if (this._loadingShowTimeout) {
      clearTimeout(this._loadingShowTimeout);
      this._loadingShowTimeout = null;
    }

    const shouldDebounce =
      this.video &&
      !this.video.paused &&
      this.video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA;

    if (shouldDebounce) {
      this._loadingShowTimeout = setTimeout(() => {
        this.elements.loadingIndicator?.classList.remove("hidden");
        this._loadingShowTimeout = null;
      }, 250);
    } else {
      this.elements.loadingIndicator?.classList.remove("hidden");
    }

    // Safety timeout: auto-hide after 10s if loading gets stuck
    // This prevents the "infinite loading" bug on live streams
    if (this._loadingSafetyTimeout) {
      clearTimeout(this._loadingSafetyTimeout);
    }
    this._loadingSafetyTimeout = setTimeout(() => {
      if (this.video && !this.video.paused && this.video.readyState >= 2) {
        this.hideLoading();
      }
    }, 10000);
  }

  hideLoading() {
    if (this._loadingShowTimeout) {
      clearTimeout(this._loadingShowTimeout);
      this._loadingShowTimeout = null;
    }
    this.elements.loadingIndicator?.classList.add("hidden");
    if (this._loadingSafetyTimeout) {
      clearTimeout(this._loadingSafetyTimeout);
      this._loadingSafetyTimeout = null;
    }
  }

  showError(message, hint = null) {
    this.hideLoading();
    if (this.elements.errorMessage) {
      this.elements.errorMessage.textContent = message;
    }
    if (this.elements.errorHint) {
      const errorHint = hint || this.getErrorHint(message);
      this.elements.errorHint.textContent = errorHint;
      this.elements.errorHint.classList.toggle("hidden", !errorHint);
    }
    this.elements.errorContainer?.classList.remove("hidden");
    this.video?.classList.add("hidden");
  }

  hideError() {
    this.elements.errorContainer?.classList.add("hidden");
    if (this.elements.errorHint) {
      this.elements.errorHint.textContent = "";
      this.elements.errorHint.classList.add("hidden");
    }
    this.video?.classList.remove("hidden");
  }

  getErrorHint(message) {
    const text = String(message || "").toLowerCase();

    if (text.includes("rede") || text.includes("servidor") || text.includes("stream")) {
      return "Pode ser instabilidade do link. Tente novamente ou volte em alguns segundos.";
    }

    if (text.includes("formato") || text.includes("codec") || text.includes("audio")) {
      return "Este arquivo pode exigir outro motor de reproducao. Tente novamente para refazer a selecao.";
    }

    if (text.includes("url") || text.includes("token")) {
      return "A sessao do link pode ter expirado. Tente novamente para renovar o acesso.";
    }

    return "Tente novamente. Se o erro continuar, recarregue a página.";
  }

  // ============================================
  // Play/Pause UI
  // ============================================

  updatePlayPauseUI(paused) {
    const { playIcon, pauseIcon } = this.elements;

    if (playIcon && pauseIcon) {
      if (paused) {
        playIcon.classList.remove("hidden");
        pauseIcon.classList.add("hidden");
      } else {
        playIcon.classList.add("hidden");
        pauseIcon.classList.remove("hidden");
      }
    }
  }

  // ============================================
  // Volume UI
  // ============================================

  updateVolumeUI(volume, muted) {
    const { muteButton, volumeOnIcon, volumeOffIcon, volumeSlider } = this.elements;
    const silent = muted || volume === 0;

    if (volumeOnIcon && volumeOffIcon) {
      if (silent) {
        volumeOnIcon.classList.add("hidden");
        volumeOffIcon.classList.remove("hidden");
      } else {
        volumeOnIcon.classList.remove("hidden");
        volumeOffIcon.classList.add("hidden");
      }
    }

    if (muteButton) {
      muteButton.setAttribute("aria-pressed", String(silent));
      muteButton.setAttribute("aria-label", silent ? "Ativar som" : "Desativar som");
    }

    if (volumeSlider) {
      volumeSlider.value = silent ? 0 : Math.round(volume * 100);
    }
  }

  // ============================================
  // Time UI
  // ============================================

  updateTimeUI(currentTime, duration) {
    const { currentTime: currentTimeEl, duration: durationEl } = this.elements;

    if (currentTimeEl) {
      currentTimeEl.textContent = this.formatTime(currentTime);
    }

    if (durationEl && duration && Number.isFinite(duration)) {
      durationEl.textContent = this.formatTime(duration);
    }

    // Update progress bar
    this.updateProgressBar(currentTime, duration);
  }

  updateProgressBar(currentTime, duration) {
    const { progressPlayed } = this.elements;
    if (!progressPlayed || !duration || !Number.isFinite(duration)) return;

    const percent = (currentTime / duration) * 100;
    progressPlayed.style.width = `${percent}%`;
  }

  /**
   * Update buffer bar to show how much is loaded
   * Netflix-style: color-coded buffer health indicator
   */
  updateBufferBar(buffered, duration, currentTime = 0) {
    const { progressBuffered } = this.elements;
    if (!progressBuffered || !duration || !Number.isFinite(duration)) return;

    // Get the end of the last buffered range
    let bufferedEnd = 0;
    if (buffered && buffered.length > 0) {
      bufferedEnd = buffered.end(buffered.length - 1);
    }

    const percent = (bufferedEnd / duration) * 100;
    progressBuffered.style.width = `${percent}%`;

    // Calculate buffer health (seconds ahead of current playback)
    const bufferAhead = bufferedEnd - currentTime;
    this.updateBufferHealthIndicator(bufferAhead);
  }

  /**
   * Update buffer health indicator with color coding
   * - Green: >60s buffer (excellent)
   * - Yellow: 30-60s buffer (good)
   * - Red: <30s buffer (may stall soon)
   */
  updateBufferHealthIndicator(bufferSeconds) {
    let indicator = this.container.querySelector("#buffer-health");

    if (!bufferDiagnosticsEnabled(window)) {
      indicator?.remove();
      return;
    }

    // Create indicator if it doesn't exist
    if (!indicator) {
      indicator = document.createElement("div");
      indicator.id = "buffer-health";
      indicator.className =
        "absolute top-2 left-2 px-1.5 py-0.5 rounded text-xs font-medium opacity-0 transition-opacity duration-300 pointer-events-none";
      indicator.setAttribute("aria-hidden", "true");

      // Insert into controls
      const controls = this.elements.controls;
      if (controls) {
        controls.appendChild(indicator);
      }
    }

    // Determine health status and color
    let color, label, showIndicator;

    if (bufferSeconds >= 60) {
      color = "bg-green-500/80";
      label = `${Math.round(bufferSeconds)}s`;
      showIndicator = false; // Hide when healthy
    } else if (bufferSeconds >= 30) {
      color = "bg-yellow-500/80";
      label = `${Math.round(bufferSeconds)}s`;
      showIndicator = true;
    } else if (bufferSeconds > 0) {
      color = "bg-red-500/80";
      label = `${Math.round(bufferSeconds)}s`;
      showIndicator = true;
    } else {
      color = "bg-red-500/80";
      label = "Buffering...";
      showIndicator = true;
    }

    // Update indicator
    indicator.textContent = label;
    indicator.className = `absolute top-2 left-2 px-1.5 py-0.5 rounded text-xs font-medium text-white transition-opacity duration-300 pointer-events-none ${color}`;
    indicator.style.opacity = showIndicator ? "1" : "0";
  }

  formatTime(seconds) {
    if (!seconds || !Number.isFinite(seconds)) return "0:00";

    const hrs = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);

    if (hrs > 0) {
      return `${hrs}:${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
    }
    return `${mins}:${secs.toString().padStart(2, "0")}`;
  }

  // ============================================
  // Speed UI
  // ============================================

  updateSpeedUI(rate) {
    const { speedLabel } = this.elements;
    if (speedLabel) {
      speedLabel.textContent = `${rate}x`;
    }
  }

  // ============================================
  // Fullscreen UI
  // ============================================

  updateFullscreenUI(isFullscreen) {
    const { expandIcon, collapseIcon } = this.elements;

    if (expandIcon && collapseIcon) {
      if (isFullscreen) {
        expandIcon.classList.add("hidden");
        collapseIcon.classList.remove("hidden");
      } else {
        expandIcon.classList.remove("hidden");
        collapseIcon.classList.add("hidden");
      }
    }
  }

  setPiPAvailable(available) {
    const { pipButton } = this.elements;
    if (!pipButton) return;

    pipButton.classList.toggle("hidden", !available);
    pipButton.disabled = !available;
    if (!available) this.updatePiPUI(false);
  }

  updatePiPUI(active) {
    const { pipButton } = this.elements;
    if (!pipButton) return;

    pipButton.setAttribute("aria-pressed", String(active));
    pipButton.setAttribute(
      "aria-label",
      active ? "Sair do modo picture-in-picture" : "Ativar picture-in-picture",
    );
    pipButton.title = active ? "Sair do picture-in-picture" : "Picture-in-picture";
  }

  // ============================================
  // Quality/Audio/Subtitle Options
  // ============================================

  updateQualityOptions(qualities, currentLevel, onSelect) {
    const container = this.elements.qualityOptions;
    if (!container || qualities.length === 0) return;

    // Set accessibility attributes
    container.setAttribute("role", "menu");
    container.setAttribute("aria-label", "Qualidade do video");

    // Clear existing content
    container.innerHTML = "";
    container.appendChild(
      this.renderOptionList(
        [{ index: -1, label: "Automatico" }, ...qualities],
        currentLevel,
        "quality-option",
      ),
    );

    container.querySelectorAll(".quality-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const level = parseInt(btn.dataset.level, 10);
        onSelect(level);
        this.updateOptionCheckmarks(container, ".quality-option", level);
      });
    });
  }

  updateAudioOptions(tracks, currentTrack, onSelect) {
    const container = this.elements.audioOptions;
    const section = this.elements.audioSection;
    if (!container) return;

    // Set accessibility attributes
    container.setAttribute("role", "menu");
    container.setAttribute("aria-label", "Faixa de audio");

    // Only show audio section if there are multiple tracks
    if (tracks.length <= 1) {
      if (section) section.classList.add("hidden");
      return;
    }

    // Show the section when we have multiple tracks
    if (section) section.classList.remove("hidden");

    container.innerHTML = "";
    container.appendChild(this.renderOptionList(tracks, currentTrack, "audio-option", "track"));

    container.querySelectorAll(".audio-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const track = parseInt(btn.dataset.track, 10);
        onSelect(track);
        this.updateOptionCheckmarks(container, ".audio-option", track, "track");
      });
    });
  }

  updateSubtitleOptions(tracks, currentTrack, onSelect) {
    const container = this.elements.subtitleOptions;
    const section = this.elements.subtitleSection;
    if (!container) return;

    // Set accessibility attributes
    container.setAttribute("role", "menu");
    container.setAttribute("aria-label", "Legendas");

    // Only show subtitle section if there are subtitles available
    if (!tracks || tracks.length === 0) {
      if (section) section.classList.add("hidden");
      return;
    }

    // Show the section when we have subtitles
    if (section) section.classList.remove("hidden");

    const allTracks = [{ index: -1, label: "Desativadas" }, ...tracks];

    container.innerHTML = "";
    container.appendChild(
      this.renderOptionList(allTracks, currentTrack, "subtitle-option", "track"),
    );

    container.querySelectorAll(".subtitle-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const track = parseInt(btn.dataset.track, 10);
        onSelect(track);
        this.updateOptionCheckmarks(container, ".subtitle-option", track, "track");
      });
    });
  }

  renderOptionList(items, currentValue, className, dataAttr = "level") {
    // Create a document fragment to build elements safely (avoid XSS from labels)
    const fragment = document.createDocumentFragment();

    items.forEach((item) => {
      const value = item.index ?? item;
      const label = item.label ?? item;
      const isSelected = currentValue === value;

      const button = document.createElement("button");
      button.type = "button";
      button.dataset[dataAttr] = value;
      button.setAttribute("role", "menuitemradio");
      button.setAttribute("aria-checked", isSelected.toString());
      button.setAttribute("aria-label", label);
      button.className = `flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors ${className}`;

      // Use textContent for label to prevent XSS
      const labelSpan = document.createElement("span");
      labelSpan.textContent = label;
      button.appendChild(labelSpan);

      // Checkmark icon
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("class", `size-4 ${isSelected ? "" : "invisible"}`);
      svg.setAttribute("aria-hidden", "true");
      svg.setAttribute("fill", "none");
      svg.setAttribute("viewBox", "0 0 24 24");
      svg.setAttribute("stroke", "currentColor");

      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.setAttribute("stroke-linecap", "round");
      path.setAttribute("stroke-linejoin", "round");
      path.setAttribute("stroke-width", "2");
      path.setAttribute("d", "M5 13l4 4L19 7");
      svg.appendChild(path);
      button.appendChild(svg);

      fragment.appendChild(button);
    });

    return fragment;
  }

  updateOptionCheckmarks(container, selector, selectedValue, dataAttr = "level") {
    container.querySelectorAll(selector).forEach((btn) => {
      const value = parseInt(btn.dataset[dataAttr], 10);
      const isSelected = value === selectedValue;
      const svg = btn.querySelector("svg");
      if (svg) {
        svg.classList.toggle("invisible", !isSelected);
      }
      // Update ARIA state
      btn.setAttribute("aria-checked", isSelected.toString());
    });
  }

  // ============================================
  // Controls Visibility (Mobile/Desktop)
  // ============================================

  showControls() {
    const { controls, topControls } = this.elements;
    if (controls) {
      controls.classList.remove("controls-hidden");
      controls.style.opacity = "1";
      controls.style.pointerEvents = this.nativeControlsMode ? "none" : "auto";
      if (topControls) {
        topControls.style.pointerEvents = "auto";
      }
      this.controlsVisible = true;
    }
  }

  hideControls() {
    const { controls, topControls } = this.elements;
    if (this.nativeControlsMode) {
      if (controls) {
        controls.style.opacity = "1";
        controls.style.pointerEvents = "none";
      }
      if (topControls) {
        topControls.style.pointerEvents = "auto";
      }
      this.controlsVisible = true;
      return;
    }

    if (controls && this._isPlayingFn()) {
      controls.classList.add("controls-hidden");
      controls.style.opacity = "0";
      controls.style.pointerEvents = "none";
      this.controlsVisible = false;
    }
  }

  setIsPlayingFn(fn) {
    this._isPlayingFn = fn;
  }

  setNativeControlsMode(enabled) {
    const { bottomControls, loadingIndicator } = this.elements;
    this.nativeControlsMode = enabled;

    if (bottomControls) {
      bottomControls.classList.toggle("hidden", enabled);
    }

    if (loadingIndicator) {
      loadingIndicator.classList.add("pointer-events-none");
      loadingIndicator.setAttribute("aria-hidden", String(enabled));
    }

    this.showControls();
  }

  toggleControlsVisibility() {
    if (this.nativeControlsMode) {
      this.showControls();
      return;
    }

    if (this.controlsVisible) {
      this.hideControls();
    } else {
      this.showControls();
      this.scheduleHideControls();
    }
  }

  scheduleHideControls() {
    this.clearHideControlsTimeout();
    this.controlsTimeout = setTimeout(() => {
      if (this._isPlayingFn()) {
        this.hideControls();
      }
    }, 3000);
  }

  clearHideControlsTimeout() {
    if (this.controlsTimeout) {
      clearTimeout(this.controlsTimeout);
      this.controlsTimeout = null;
    }
  }

  /**
   * Show quality change notification
   * @param {string} quality - The new quality level (e.g., "720p", "Auto: 1080p")
   */
  showQualityChange(quality) {
    // Remove existing notification
    const existing = this.container.querySelector(".quality-toast");
    if (existing) existing.remove();

    const toast = document.createElement("div");
    toast.className =
      "quality-toast absolute top-4 right-4 pointer-events-none z-30 animate-fade-in-out";

    // Create using DOM API for security
    const inner = document.createElement("div");
    inner.className =
      "px-3 py-1.5 rounded bg-black/70 backdrop-blur-sm text-white text-sm font-medium flex items-center gap-2";

    // HD icon
    const icon = document.createElement("span");
    icon.className = "text-xs bg-white/20 px-1 rounded";
    icon.textContent = "HD";

    const text = document.createElement("span");
    text.textContent = quality;

    inner.appendChild(icon);
    inner.appendChild(text);
    toast.appendChild(inner);
    this.container.appendChild(toast);

    // Remove after animation
    setTimeout(() => toast.remove(), 2000);
  }

  // ============================================
  // Cleanup
  // ============================================

  destroy() {
    this.clearHideControlsTimeout();

    // Clear loading safety timeout
    if (this._loadingSafetyTimeout) {
      clearTimeout(this._loadingSafetyTimeout);
      this._loadingSafetyTimeout = null;
    }

    // Cleanup focus traps
    for (const focusTrap of this.focusTraps.values()) {
      focusTrap.deactivate();
    }
    this.focusTraps.clear();

    // Cleanup mutation observers
    if (this._menuObservers) {
      for (const observer of this._menuObservers) {
        observer.disconnect();
      }
      this._menuObservers = [];
    }
  }
}

export default PlayerUI;
