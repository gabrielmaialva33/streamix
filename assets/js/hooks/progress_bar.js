/**
 * ProgressBar Hook for Video Timeline
 *
 * Features:
 * - Click to seek
 * - Drag to seek
 * - Visual progress and buffer indicators
 * - Works with both native video and AVPlayer
 */
const ProgressBar = {
  mounted() {
    this.isDragging = false;
    this.pendingSeekTime = null;
    this.suppressClickUntil = 0;
    this.progressContainer = this.el;
    this.progressPlayed = this.el.querySelector("#progress-played");
    this.progressBuffered = this.el.querySelector("#progress-buffered");

    // Get the video element and player container
    this.playerContainer = this.el.closest("[phx-hook='VideoPlayer']");
    this.video = this.playerContainer?.querySelector("video");

    if (!this.playerContainer) {
      console.warn("ProgressBar: player container not found");
      return;
    }

    this.setupEventListeners();
  },

  /**
   * Get the VideoPlayer hook instance from the container
   */
  getVideoPlayerHook() {
    // VideoPlayer hook exposes itself on the element
    return this.playerContainer?.__videoPlayerHook;
  },

  setupEventListeners() {
    // Bind handlers so we can remove them later
    this.handleClick = (e) => {
      if (Date.now() < this.suppressClickUntil) return;
      this.seekToPosition(e, { commit: true });
    };
    this.handleMouseDown = (e) => {
      this.isDragging = true;
      this.seekToPosition(e, { commit: false });
    };
    this.handleMouseMove = (e) => {
      if (this.isDragging) {
        this.seekToPosition(e, { commit: false });
      }
    };
    this.handleMouseUp = () => {
      this.finishDrag();
    };
    this.handleTouchStart = (e) => {
      this.isDragging = true;
      this.seekToPosition(e.touches[0], { commit: false });
    };
    this.handleTouchMove = (e) => {
      if (this.isDragging) {
        this.seekToPosition(e.touches[0], { commit: false });
      }
    };
    this.handleTouchEnd = () => {
      this.finishDrag();
    };
    this.handleTimeUpdate = () => this.updateProgress();
    this.handleProgress = () => this.updateBuffer();
    this.handleLoadedMetadata = () => this.updateProgress();
    this.onKeyDown = (e) => this.handleKeyDown(e);

    // Click to seek
    this.progressContainer.addEventListener("click", this.handleClick);
    this.progressContainer.addEventListener("keydown", this.onKeyDown);

    // Drag functionality
    this.progressContainer.addEventListener("mousedown", this.handleMouseDown);
    document.addEventListener("mousemove", this.handleMouseMove);
    document.addEventListener("mouseup", this.handleMouseUp);

    // Touch support.
    // iOS Safari: mark as passive so the browser doesn't wait to see if
    // preventDefault() will be called before starting the scroll — none
    // of these handlers call preventDefault(), so passive is correct and
    // it also silences the Chrome "non-passive listener" console warning.
    this.progressContainer.addEventListener("touchstart", this.handleTouchStart, { passive: true });
    document.addEventListener("touchmove", this.handleTouchMove, { passive: true });
    document.addEventListener("touchend", this.handleTouchEnd, { passive: true });

    // Update progress bar on timeupdate (for native video)
    // AVPlayer updates are handled by VideoPlayer hook's time interval
    if (this.video) {
      this.video.addEventListener("timeupdate", this.handleTimeUpdate);
      this.video.addEventListener("progress", this.handleProgress);
      this.video.addEventListener("loadedmetadata", this.handleLoadedMetadata);
    }
  },

  finishDrag() {
    if (!this.isDragging) return;

    this.isDragging = false;
    this.suppressClickUntil = Date.now() + 350;

    if (this.pendingSeekTime !== null) {
      this.commitSeek(this.pendingSeekTime);
      this.pendingSeekTime = null;
    }
  },

  seekToPosition(e, { commit = false } = {}) {
    const hook = this.getVideoPlayerHook();
    const duration = hook?.getDuration?.() || this.video?.duration;

    if (!duration || !Number.isFinite(duration)) return;

    const rect = this.progressContainer.getBoundingClientRect();
    const pos = (e.clientX - rect.left) / rect.width;
    const clampedPos = Math.max(0, Math.min(1, pos));
    const seekTime = clampedPos * duration;

    if (commit) {
      this.commitSeek(seekTime);
    } else {
      this.pendingSeekTime = seekTime;
    }

    // Update progress bar immediately for responsive feel
    if (this.progressPlayed) {
      this.progressPlayed.style.width = `${clampedPos * 100}%`;
    }
  },

  commitSeek(seekTime) {
    const hook = this.getVideoPlayerHook();

    // Use VideoPlayer hook's seekTo method (works with both native and AVPlayer)
    if (hook?.seekTo) {
      hook.seekTo(seekTime);
    } else if (this.video) {
      // Fallback to direct video element
      this.video.currentTime = seekTime;
    }
  },

  formatAriaTime(seconds) {
    const s = Math.floor(Math.max(0, seconds || 0));
    const hours = Math.floor(s / 3600);
    const minutes = Math.floor((s % 3600) / 60);
    const remainingSeconds = s % 60;
    const pad = (n) => String(n).padStart(2, "0");

    if (hours > 0) {
      return `${hours}:${pad(minutes)}:${pad(remainingSeconds)}`;
    }
    return `${pad(minutes)}:${pad(remainingSeconds)}`;
  },

  updateAria(currentTime, duration) {
    if (!this.progressContainer) return;
    const cur = Math.round(currentTime || 0);
    const dur = Math.round(duration || 0);
    this.progressContainer.setAttribute("aria-valuenow", String(cur));
    this.progressContainer.setAttribute("aria-valuemin", "0");
    this.progressContainer.setAttribute("aria-valuemax", String(dur));
    this.progressContainer.setAttribute(
      "aria-valuetext",
      `${this.formatAriaTime(cur)} de ${this.formatAriaTime(dur)}`,
    );
  },

  handleKeyDown(e) {
    if (this.progressContainer.getAttribute("aria-disabled") === "true") return;

    const hook = this.getVideoPlayerHook();
    const duration = hook?.getDuration?.() || this.video?.duration || 0;
    const currentTime = hook?.getCurrentTime?.() ?? this.video?.currentTime ?? 0;

    if (!duration || !Number.isFinite(duration)) return;

    let delta = null;
    let targetTime = null;

    switch (e.key) {
      case "ArrowLeft":
        delta = -5;
        break;
      case "ArrowRight":
        delta = 5;
        break;
      case "ArrowDown":
        delta = -10;
        break;
      case "ArrowUp":
        delta = 10;
        break;
      case "PageDown":
        delta = -30;
        break;
      case "PageUp":
        delta = 30;
        break;
      case "Home":
        targetTime = 0;
        break;
      case "End":
        targetTime = duration;
        break;
      default:
        return;
    }

    e.preventDefault();
    e.stopPropagation();

    const newTime =
      targetTime !== null ? targetTime : Math.max(0, Math.min(duration, currentTime + delta));
    this.commitSeek(newTime);

    this.updateAria(newTime, duration);
    if (this.progressPlayed) {
      this.progressPlayed.style.width = `${(newTime / duration) * 100}%`;
    }
  },

  updateProgress() {
    const hook = this.getVideoPlayerHook();

    // If using AVPlayer, the VideoPlayer hook handles progress updates
    if (hook?.usingAVPlayer) return;

    if (!this.video?.duration || !Number.isFinite(this.video.duration)) return;

    const currentTime = this.video.currentTime || 0;
    const duration = this.video.duration;

    this.updateAria(currentTime, duration);

    if (!this.progressPlayed) return;

    const percent = (currentTime / duration) * 100;
    this.progressPlayed.style.width = `${percent}%`;
  },

  updateBuffer() {
    const hook = this.getVideoPlayerHook();

    // Buffer tracking not available for AVPlayer
    if (hook?.usingAVPlayer) return;

    if (!this.video?.duration || !Number.isFinite(this.video.duration)) return;
    if (!this.progressBuffered) return;

    // Get the furthest buffered range
    let bufferedEnd = 0;
    for (let i = 0; i < this.video.buffered.length; i++) {
      if (this.video.buffered.end(i) > bufferedEnd) {
        bufferedEnd = this.video.buffered.end(i);
      }
    }

    const percent = (bufferedEnd / this.video.duration) * 100;
    this.progressBuffered.style.width = `${percent}%`;
  },

  destroyed() {
    this.isDragging = false;

    // Remove container listeners
    if (this.progressContainer) {
      this.progressContainer.removeEventListener("click", this.handleClick);
      this.progressContainer.removeEventListener("mousedown", this.handleMouseDown);
      this.progressContainer.removeEventListener("touchstart", this.handleTouchStart);
      this.progressContainer.removeEventListener("keydown", this.onKeyDown);
    }

    // Remove document-level listeners
    document.removeEventListener("mousemove", this.handleMouseMove);
    document.removeEventListener("mouseup", this.handleMouseUp);
    document.removeEventListener("touchmove", this.handleTouchMove);
    document.removeEventListener("touchend", this.handleTouchEnd);

    // Remove video element listeners
    if (this.video) {
      this.video.removeEventListener("timeupdate", this.handleTimeUpdate);
      this.video.removeEventListener("progress", this.handleProgress);
      this.video.removeEventListener("loadedmetadata", this.handleLoadedMetadata);
    }
  },
};

export default ProgressBar;
