/**
 * Keyboard Manager
 *
 * Handles YouTube-style keyboard shortcuts for the video player.
 * Extracted from video_player.js for better separation of concerns.
 */

/**
 * @typedef {Object} KeyboardActions
 * @property {function} togglePlayPause - Toggle play/pause
 * @property {function} toggleMute - Toggle mute
 * @property {function} toggleFullscreen - Toggle fullscreen
 * @property {function} togglePiP - Toggle Picture-in-Picture
 * @property {function(number): void} adjustVolume - Adjust volume by delta
 * @property {function(number): void} seek - Seek by seconds
 * @property {function(number): void} seekTo - Seek to absolute time
 * @property {function(number): void} setPlaybackRate - Set playback rate
 * @property {function(): number} getDuration - Get video duration
 * @property {function(): boolean} isPaused - Check if video is paused
 * @property {function(): boolean} isMuted - Check if video is muted
 * @property {function(): boolean} isPiPSupported - Check if PiP is supported
 * @property {function(): number} getPlaybackRate - Get current playback rate
 */

/**
 * @typedef {Object} KeyboardManagerOptions
 * @property {string} contentType - "live" or "vod"
 * @property {KeyboardActions} actions - Player action callbacks
 * @property {function(string): void} [showFeedback] - Show visual feedback
 */

export class KeyboardManager {
  /**
   * @param {KeyboardManagerOptions} options
   */
  constructor(options) {
    this.contentType = options.contentType || "live";
    this.actions = options.actions;
    this.showFeedback = options.showFeedback || (() => {});

    this.keyHandler = null;
    this.isActive = false;
  }

  /**
   * Start listening for keyboard events
   */
  start() {
    if (this.isActive) return;

    this.keyHandler = (e) => this.handleKeyDown(e);
    document.addEventListener("keydown", this.keyHandler);
    this.isActive = true;
  }

  /**
   * Stop listening for keyboard events
   */
  stop() {
    if (!this.isActive) return;

    if (this.keyHandler) {
      document.removeEventListener("keydown", this.keyHandler);
      this.keyHandler = null;
    }
    this.isActive = false;
  }

  /**
   * Update content type (affects which shortcuts are available)
   * @param {string} contentType
   */
  setContentType(contentType) {
    this.contentType = contentType;
  }

  /**
   * Handle keydown events
   * @param {KeyboardEvent} e
   */
  handleKeyDown(e) {
    // Ignore if typing in an input field
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
      return;
    }

    // Ignore if modifier keys are pressed (except Shift for < and >)
    if (e.ctrlKey || e.altKey || e.metaKey) {
      return;
    }

    switch (e.key) {
      // Fullscreen
      case "f":
      case "F":
        this.actions.toggleFullscreen();
        this.showFeedback("fullscreen");
        break;

      // Play/Pause
      case " ":
      case "k":
      case "K":
        e.preventDefault();
        this.showFeedback(this.actions.isPaused() ? "play" : "pause");
        this.actions.togglePlayPause();
        break;

      // Mute
      case "m":
      case "M":
        {
          const wasMuted = this.actions.isMuted();
          this.actions.toggleMute();
          this.showFeedback(wasMuted ? "unmute" : "mute");
        }
        break;

      // Picture-in-Picture
      case "p":
      case "P":
        if (this.actions.isPiPSupported()) {
          this.actions.togglePiP();
          this.showFeedback("pip");
        }
        break;

      // Volume Up
      case "ArrowUp":
        e.preventDefault();
        this.actions.adjustVolume(0.1);
        this.showFeedback("volumeUp");
        break;

      // Volume Down
      case "ArrowDown":
        e.preventDefault();
        this.actions.adjustVolume(-0.1);
        this.showFeedback("volumeDown");
        break;

      // Seek Backward (VOD only)
      case "ArrowLeft":
      case "j":
      case "J":
        if (this.contentType === "vod") {
          e.preventDefault();
          this.actions.seek(-10);
          this.showFeedback("backward");
        }
        break;

      // Seek Forward (VOD only)
      case "ArrowRight":
      case "l":
      case "L":
        if (this.contentType === "vod") {
          e.preventDefault();
          this.actions.seek(10);
          this.showFeedback("forward");
        }
        break;

      // Percentage seek (VOD only) - 0-9 keys
      case "0":
      case "1":
      case "2":
      case "3":
      case "4":
      case "5":
      case "6":
      case "7":
      case "8":
      case "9":
        if (this.contentType === "vod") {
          e.preventDefault();
          const percent = parseInt(e.key, 10) / 10;
          const duration = this.actions.getDuration();
          if (duration > 0) {
            this.actions.seekTo(duration * percent);
          }
        }
        break;

      // Decrease playback speed
      case "<":
        {
          const currentRate = this.actions.getPlaybackRate();
          const newRate = Math.max(0.25, currentRate - 0.25);
          this.actions.setPlaybackRate(newRate);
        }
        break;

      // Increase playback speed
      case ">":
        {
          const currentRate = this.actions.getPlaybackRate();
          const newRate = Math.min(2, currentRate + 0.25);
          this.actions.setPlaybackRate(newRate);
        }
        break;
    }
  }

  /**
   * Destroy the keyboard manager
   */
  destroy() {
    this.stop();
    this.actions = null;
    this.showFeedback = null;
  }
}

export default KeyboardManager;
