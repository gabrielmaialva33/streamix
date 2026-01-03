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
    // Click to seek
    this.progressContainer.addEventListener("click", (e) => {
      this.seekToPosition(e);
    });

    // Drag functionality
    this.progressContainer.addEventListener("mousedown", (e) => {
      this.isDragging = true;
      this.seekToPosition(e);
    });

    document.addEventListener("mousemove", (e) => {
      if (this.isDragging) {
        this.seekToPosition(e);
      }
    });

    document.addEventListener("mouseup", () => {
      this.isDragging = false;
    });

    // Touch support
    this.progressContainer.addEventListener("touchstart", (e) => {
      this.isDragging = true;
      this.seekToPosition(e.touches[0]);
    });

    document.addEventListener("touchmove", (e) => {
      if (this.isDragging) {
        this.seekToPosition(e.touches[0]);
      }
    });

    document.addEventListener("touchend", () => {
      this.isDragging = false;
    });

    // Update progress bar on timeupdate (for native video)
    // AVPlayer updates are handled by VideoPlayer hook's time interval
    if (this.video) {
      this.video.addEventListener("timeupdate", () => this.updateProgress());
      this.video.addEventListener("progress", () => this.updateBuffer());
      this.video.addEventListener("loadedmetadata", () => this.updateProgress());
    }
  },

  seekToPosition(e) {
    const hook = this.getVideoPlayerHook();
    const duration = hook?.getDuration?.() || this.video?.duration;

    if (!duration || !isFinite(duration)) return;

    const rect = this.progressContainer.getBoundingClientRect();
    const pos = (e.clientX - rect.left) / rect.width;
    const clampedPos = Math.max(0, Math.min(1, pos));
    const seekTime = clampedPos * duration;

    // Use VideoPlayer hook's seekTo method (works with both native and AVPlayer)
    if (hook?.seekTo) {
      hook.seekTo(seekTime);
    } else if (this.video) {
      // Fallback to direct video element
      this.video.currentTime = seekTime;
    }

    // Update progress bar immediately for responsive feel
    if (this.progressPlayed) {
      this.progressPlayed.style.width = `${clampedPos * 100}%`;
    }
  },

  updateProgress() {
    const hook = this.getVideoPlayerHook();

    // If using AVPlayer, the VideoPlayer hook handles progress updates
    if (hook?.usingAVPlayer) return;

    if (!this.video || !this.video.duration || !isFinite(this.video.duration)) return;
    if (!this.progressPlayed) return;

    const percent = (this.video.currentTime / this.video.duration) * 100;
    this.progressPlayed.style.width = `${percent}%`;
  },

  updateBuffer() {
    const hook = this.getVideoPlayerHook();

    // Buffer tracking not available for AVPlayer
    if (hook?.usingAVPlayer) return;

    if (!this.video || !this.video.duration || !isFinite(this.video.duration)) return;
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
  },
};

export default ProgressBar;
