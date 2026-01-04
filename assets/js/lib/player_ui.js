/**
 * Player UI Manager
 *
 * Handles UI updates for the video player.
 * HTML structure is in HEEX templates - this only manages state/visibility.
 */

/**
 * PlayerUI class - manages UI state updates
 */
export class PlayerUI {
  constructor(container) {
    this.container = container;
    this.video = container.querySelector("video");

    // Cache DOM elements
    this.elements = {
      // Loading/Error
      loadingIndicator: container.querySelector("#loading-indicator"),
      errorContainer: container.querySelector("#error-container"),
      errorMessage: container.querySelector(".error-message"),
      retryBtn: container.querySelector(".retry-btn"),

      // Play/Pause
      playIcon: container.querySelector(".play-icon"),
      pauseIcon: container.querySelector(".pause-icon"),
      centerPlay: container.querySelector("#center-play"),

      // Volume
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

      // Controls container
      controls: container.querySelector("#player-controls"),

      // Quality/Audio/Subtitle containers
      qualityOptions: container.querySelector("#quality-options"),
      audioOptions: container.querySelector("#audio-options"),
      subtitleOptions: container.querySelector("#subtitle-options"),
    };

    // Controls visibility state
    this.controlsVisible = true;
    this.controlsTimeout = null;
    this.isTouchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;
  }

  // ============================================
  // Loading/Error States
  // ============================================

  showLoading() {
    this.elements.loadingIndicator?.classList.remove("hidden");
  }

  hideLoading() {
    this.elements.loadingIndicator?.classList.add("hidden");
  }

  showError(message) {
    this.hideLoading();
    if (this.elements.errorMessage) {
      this.elements.errorMessage.textContent = message;
    }
    this.elements.errorContainer?.classList.remove("hidden");
    this.video?.classList.add("hidden");
  }

  hideError() {
    this.elements.errorContainer?.classList.add("hidden");
    this.video?.classList.remove("hidden");
  }

  // ============================================
  // Play/Pause UI
  // ============================================

  updatePlayPauseUI(paused) {
    const { playIcon, pauseIcon, centerPlay } = this.elements;

    if (playIcon && pauseIcon) {
      if (paused) {
        playIcon.classList.remove("hidden");
        pauseIcon.classList.add("hidden");
      } else {
        playIcon.classList.add("hidden");
        pauseIcon.classList.remove("hidden");
      }
    }

    // Flash center play button on pause
    if (centerPlay && paused) {
      centerPlay.classList.add("opacity-100");
      setTimeout(() => centerPlay.classList.remove("opacity-100"), 300);
    }
  }

  // ============================================
  // Volume UI
  // ============================================

  updateVolumeUI(volume, muted) {
    const { volumeOnIcon, volumeOffIcon, volumeSlider } = this.elements;

    if (volumeOnIcon && volumeOffIcon) {
      if (muted || volume === 0) {
        volumeOnIcon.classList.add("hidden");
        volumeOffIcon.classList.remove("hidden");
      } else {
        volumeOnIcon.classList.remove("hidden");
        volumeOffIcon.classList.add("hidden");
      }
    }

    if (volumeSlider) {
      volumeSlider.value = muted ? 0 : Math.round(volume * 100);
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

    if (durationEl && duration && isFinite(duration)) {
      durationEl.textContent = this.formatTime(duration);
    }

    // Update progress bar
    this.updateProgressBar(currentTime, duration);
  }

  updateProgressBar(currentTime, duration) {
    const { progressPlayed } = this.elements;
    if (!progressPlayed || !duration || !isFinite(duration)) return;

    const percent = (currentTime / duration) * 100;
    progressPlayed.style.width = `${percent}%`;
  }

  /**
   * Update buffer bar to show how much is loaded
   */
  updateBufferBar(buffered, duration) {
    const { progressBuffered } = this.elements;
    if (!progressBuffered || !duration || !isFinite(duration)) return;

    // Get the end of the last buffered range
    let bufferedEnd = 0;
    if (buffered && buffered.length > 0) {
      bufferedEnd = buffered.end(buffered.length - 1);
    }

    const percent = (bufferedEnd / duration) * 100;
    progressBuffered.style.width = `${percent}%`;
  }

  formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) return "0:00";

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

  // ============================================
  // Quality/Audio/Subtitle Options
  // ============================================

  updateQualityOptions(qualities, currentLevel, onSelect) {
    const container = this.elements.qualityOptions;
    if (!container || qualities.length === 0) return;

    container.innerHTML = this.renderOptionList(
      [{ index: -1, label: "Automatico" }, ...qualities],
      currentLevel,
      'quality-option'
    );

    container.querySelectorAll(".quality-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const level = parseInt(btn.dataset.level, 10);
        onSelect(level);
        this.updateOptionCheckmarks(container, '.quality-option', level);
      });
    });
  }

  updateAudioOptions(tracks, currentTrack, onSelect) {
    const container = this.elements.audioOptions;
    if (!container) return;

    if (tracks.length === 0) {
      container.innerHTML = `<div class="px-4 py-2 text-sm text-white/50">Padrao</div>`;
      return;
    }

    container.innerHTML = this.renderOptionList(tracks, currentTrack, 'audio-option', 'track');

    container.querySelectorAll(".audio-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const track = parseInt(btn.dataset.track, 10);
        onSelect(track);
        this.updateOptionCheckmarks(container, '.audio-option', track, 'track');
      });
    });
  }

  updateSubtitleOptions(tracks, currentTrack, onSelect) {
    const container = this.elements.subtitleOptions;
    if (!container) return;

    const allTracks = [{ index: -1, label: "Desativadas" }, ...tracks];

    container.innerHTML = this.renderOptionList(allTracks, currentTrack, 'subtitle-option', 'track');

    container.querySelectorAll(".subtitle-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        const track = parseInt(btn.dataset.track, 10);
        onSelect(track);
        this.updateOptionCheckmarks(container, '.subtitle-option', track, 'track');
      });
    });
  }

  renderOptionList(items, currentValue, className, dataAttr = 'level') {
    return items.map((item) => {
      const value = item.index ?? item;
      const label = item.label ?? item;
      const isSelected = currentValue === value;

      return `
        <button type="button" data-${dataAttr}="${value}"
          role="menuitemradio"
          aria-checked="${isSelected}"
          aria-label="${label}"
          class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors ${className}">
          <span>${label}</span>
          <svg class="size-4 ${isSelected ? "" : "invisible"}" aria-hidden="true" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
          </svg>
        </button>
      `;
    }).join("");
  }

  updateOptionCheckmarks(container, selector, selectedValue, dataAttr = 'level') {
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
    const { controls } = this.elements;
    if (controls) {
      controls.classList.remove("controls-hidden");
      controls.style.opacity = "1";
      this.controlsVisible = true;
    }
  }

  hideControls() {
    const { controls } = this.elements;
    if (controls && this.video && !this.video.paused) {
      controls.classList.add("controls-hidden");
      controls.style.opacity = "0";
      this.controlsVisible = false;
    }
  }

  toggleControlsVisibility() {
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
      if (this.video && !this.video.paused) {
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

  // ============================================
  // Play Button Overlay
  // ============================================

  showPlayButton(onClick) {
    const existing = this.container.querySelector(".play-overlay");
    if (existing) existing.remove();

    const playOverlay = document.createElement("div");
    playOverlay.className =
      "play-overlay absolute inset-0 flex items-center justify-center bg-black/50 cursor-pointer z-10";
    playOverlay.setAttribute("role", "button");
    playOverlay.setAttribute("aria-label", "Reproduzir video");
    playOverlay.setAttribute("tabindex", "0");
    playOverlay.innerHTML = `
      <svg class="w-24 h-24 text-white opacity-80 hover:opacity-100 transition-opacity" aria-hidden="true" fill="currentColor" viewBox="0 0 24 24">
        <path d="M8 5v14l11-7z" />
      </svg>
    `;

    const handlePlay = () => {
      playOverlay.remove();
      onClick?.();
    };

    playOverlay.addEventListener("click", handlePlay);
    playOverlay.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        handlePlay();
      }
    });

    this.container.appendChild(playOverlay);
  }

  removePlayButton() {
    const existing = this.container.querySelector(".play-overlay");
    if (existing) existing.remove();
  }

  // ============================================
  // Keyboard Shortcut Feedback (YouTube-style)
  // ============================================

  /**
   * Show floating icon feedback for keyboard shortcuts
   * @param {string} icon - Icon type: 'play', 'pause', 'mute', 'unmute', 'forward', 'backward', 'volumeUp', 'volumeDown'
   */
  showShortcutFeedback(icon) {
    // Remove existing feedback
    const existing = this.container.querySelector(".shortcut-feedback");
    if (existing) existing.remove();

    const iconSvg = this.getShortcutIcon(icon);
    if (!iconSvg) return;

    const feedback = document.createElement("div");
    feedback.className = "shortcut-feedback absolute inset-0 flex items-center justify-center pointer-events-none z-30";
    feedback.innerHTML = `
      <div class="p-4 rounded-full bg-black/60 backdrop-blur-sm animate-shortcut-feedback">
        ${iconSvg}
      </div>
    `;

    this.container.appendChild(feedback);

    // Remove after animation
    setTimeout(() => feedback.remove(), 500);
  }

  getShortcutIcon(icon) {
    const icons = {
      play: '<svg class="size-12 text-white" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>',
      pause: '<svg class="size-12 text-white" fill="currentColor" viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>',
      mute: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>',
      unmute: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072m2.828-9.9a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/></svg>',
      forward: '<svg class="size-12 text-white" fill="currentColor" viewBox="0 0 24 24"><path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z"/></svg>',
      backward: '<svg class="size-12 text-white" fill="currentColor" viewBox="0 0 24 24"><path d="M11 18V6l-8.5 6 8.5 6zm.5-6l8.5 6V6l-8.5 6z"/></svg>',
      volumeUp: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m0 0l-4-4H4v-4h4l4-4v12z"/><path stroke-linecap="round" stroke-width="2" d="M19 12h2"/></svg>',
      volumeDown: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v12m0 0l-4-4H4v-4h4l4-4v12z"/><path stroke-linecap="round" stroke-width="2" d="M16 12h-2"/></svg>',
      fullscreen: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 8V4m0 0h4M4 4l5 5m11-1V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5m11 5l-5-5m5 5v-4m0 4h-4"/></svg>',
      pip: '<svg class="size-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h12a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V6z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 10h4v4h-4z"/></svg>',
    };
    return icons[icon] || null;
  }

  // ============================================
  // Cleanup
  // ============================================

  destroy() {
    this.clearHideControlsTimeout();
  }
}

export default PlayerUI;
