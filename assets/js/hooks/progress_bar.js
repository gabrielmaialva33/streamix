/**
 * ProgressBar Hook for Video Timeline
 *
 * Features:
 * - Click to seek
 * - Drag to seek
 * - Visual progress and buffer indicators
 */
const ProgressBar = {
  mounted() {
    this.isDragging = false;
    this.progressContainer = this.el;
    this.progressPlayed = this.el.querySelector("#progress-played");
    this.progressBuffered = this.el.querySelector("#progress-buffered");

    // Get the video element from the parent player container
    this.playerContainer = this.el.closest("[phx-hook='VideoPlayer']");
    this.video = this.playerContainer?.querySelector("video");

    if (!this.video) {
      console.warn("ProgressBar: video element not found");
      return;
    }

    this.setupEventListeners();
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

    // Update progress bar on timeupdate
    this.video.addEventListener("timeupdate", () => this.updateProgress());
    this.video.addEventListener("progress", () => this.updateBuffer());
    this.video.addEventListener("loadedmetadata", () => this.updateProgress());
  },

  seekToPosition(e) {
    if (!this.video || !this.video.duration || !isFinite(this.video.duration)) return;

    const rect = this.progressContainer.getBoundingClientRect();
    const pos = (e.clientX - rect.left) / rect.width;
    const clampedPos = Math.max(0, Math.min(1, pos));

    this.video.currentTime = clampedPos * this.video.duration;
  },

  updateProgress() {
    if (!this.video || !this.video.duration || !isFinite(this.video.duration)) return;
    if (!this.progressPlayed) return;

    const percent = (this.video.currentTime / this.video.duration) * 100;
    this.progressPlayed.style.width = `${percent}%`;
  },

  updateBuffer() {
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
