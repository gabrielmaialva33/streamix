import { playerLogger as log } from "../core/logger.js";

export class NativeBufferingController {
  constructor({
    contentType,
    emit,
    logger = log,
    metrics,
    now = () => Date.now(),
    playerUI,
    timerApi = globalThis,
    video,
  }) {
    this.contentType = contentType;
    this.emit = emit;
    this.log = logger;
    this.metrics = metrics;
    this.now = now;
    this.playerUI = playerUI;
    this.timerApi = timerApi;
    this.video = video;

    this.debounce = null;
    this.destroyed = false;
    this.lastTimelineSeekAt = 0;
    this.resumeAfterSeek = false;
  }

  handlePause() {
    if (this.destroyed) return;
    this.clear();
    this.playerUI?.hideLoading();
    this.emit("buffering", { buffering: false });
    this.metrics?.setBuffering(false);
  }

  handleTimeUpdate() {
    if (this.destroyed || !this.video || this.video.paused || this.video.readyState < 3) return;

    this.playerUI.hideLoading();
    this.metrics?.markPlaying();
  }

  handleProgress() {
    if (this.destroyed || !this.video || this.video.paused || this.video.buffered.length === 0) {
      return;
    }

    const bufferedEnd = this.video.buffered.end(this.video.buffered.length - 1);
    if (bufferedEnd - this.video.currentTime <= 1) return;

    this.playerUI.hideLoading();
    this.metrics?.setBuffering(false);
  }

  handleSeeking() {
    if (this.destroyed) return;
    this.lastTimelineSeekAt = this.now();
    this.clear();
  }

  prepareSeek() {
    if (this.destroyed) return;
    this.lastTimelineSeekAt = this.now();
    this.resumeAfterSeek = !this.video?.paused;
  }

  handleSeeked() {
    if (this.destroyed || !this.resumeAfterSeek || !this.video) return;

    this.resumeAfterSeek = false;
    this.video.play().catch((error) => {
      if (error.name === "AbortError") return;
      this.log.debug("[VideoPlayer] native post-seek play() skipped:", error.message);
    });
  }

  handleWaiting() {
    if (this.destroyed) return;
    this.clear();

    const seekGraceMs = this.contentType === "vod" ? 1_600 : 0;
    const isRecentTimelineSeek = this.now() - this.lastTimelineSeekAt < seekGraceMs;
    const bufferingDelay =
      this.contentType === "live" ? 650 : isRecentTimelineSeek ? seekGraceMs : 200;

    this.debounce = this.timerApi.setTimeout(() => {
      this.debounce = null;
      if (
        !this.destroyed &&
        this.video &&
        !this.video.paused &&
        this.video.readyState < 3 &&
        this.now() - this.lastTimelineSeekAt >= seekGraceMs
      ) {
        this.playerUI.showLoading();
        this.emit("buffering", { buffering: true });
        this.metrics?.setBuffering(true);
      }
    }, bufferingDelay);
  }

  handlePlaying() {
    if (this.destroyed) return;
    this.clear();
    this.emit("buffering", { buffering: false });
    this.metrics?.markPlaying();
    this.playerUI.hideLoading();
    this.playerUI.hideError();
  }

  handleCanPlayThrough() {
    if (this.destroyed) return;
    this.clear();
    this.emit("buffering", { buffering: false });
    this.metrics?.setBuffering(false);
    this.playerUI.hideLoading();
  }

  clear() {
    if (this.debounce === null) return;
    this.timerApi.clearTimeout(this.debounce);
    this.debounce = null;
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.clear();
    this.resumeAfterSeek = false;
  }
}
