import { playerLogger as log } from "../core/logger.js";
import { getHls, isHlsJsSupported } from "../media/player_libs.js";
import { getStreamType } from "../media/stream_loader.js";
import {
  nextEpisodeCountdownWidth,
  nextEpisodePath,
  shouldTriggerNextEpisode,
} from "./next_episode.js";

export class NextEpisodeController {
  constructor({
    documentRef = globalThis.document,
    episode,
    hlsLoader = getHls,
    hlsSupported = isHlsJsSupported,
    logger = log,
    onPlay = null,
    root,
    scheduler = globalThis,
    streamType = getStreamType,
    windowRef = globalThis.window,
  }) {
    this.document = documentRef;
    this.episode = episode;
    this.hlsLoader = hlsLoader;
    this.hlsSupported = hlsSupported;
    this.log = logger;
    this.onPlay = onPlay;
    this.root = root;
    this.scheduler = scheduler;
    this.streamType = streamType;
    this.window = windowRef;

    this.countdownInterval = null;
    this.hideTimeout = null;
    this.preconnect = null;
    this.preloader = null;
    this.shown = false;
    this.destroyed = false;
  }

  check(currentTime, duration) {
    if (!this.episode || this.shown || this.destroyed) return;
    if (!shouldTriggerNextEpisode(currentTime, duration)) return;

    this.show();
    void this.preload();
  }

  show() {
    if (this.shown || this.destroyed) return;
    this.shown = true;

    const overlay = this.root?.querySelector("#next-episode-overlay");
    if (!overlay) return;

    this.overlay = overlay;
    overlay.classList.remove("hidden");
    this.scheduler.requestAnimationFrame(() => {
      if (this.destroyed) return;
      overlay.classList.add("opacity-100");
      overlay.classList.remove("translate-x-4");
    });

    this.playButton = overlay.querySelector("#play-next-btn");
    this.cancelButton = overlay.querySelector("#cancel-next-btn");
    const countdownBar = overlay.querySelector("#next-countdown-bar");

    if (this.playButton) {
      this.playButton.onclick = () => this.runSafely("playNextEpisode", () => this.play());
    }
    if (this.cancelButton) {
      this.cancelButton.onclick = () => this.hide();
    }

    let countdown = 10;
    this.countdownInterval = this.scheduler.setInterval(() => {
      countdown -= 1;
      if (countdownBar) {
        countdownBar.style.width = `${nextEpisodeCountdownWidth(countdown)}%`;
      }
      if (countdown <= 0) {
        this.runSafely("playNextEpisode countdown", () => this.play());
      }
    }, 1_000);

    this.log.debug("[VideoPlayer] Showing next episode overlay:", this.episode.title);
  }

  hide() {
    this.clearCountdown();

    if (this.overlay) {
      this.overlay.classList.remove("opacity-100");
      this.overlay.classList.add("translate-x-4");
      this.hideTimeout = this.scheduler.setTimeout(() => {
        this.hideTimeout = null;
        if (!this.destroyed) this.overlay?.classList.add("hidden");
      }, 300);
    }

    this.destroyPreloader();
  }

  play() {
    if (!this.episode || this.destroyed) return;

    this.hide();

    if (typeof this.onPlay === "function") {
      this.log.debug("[VideoPlayer] Delegating next episode transition:", this.episode.title);
      this.onPlay(this.episode);
      return;
    }

    const path = nextEpisodePath(this.episode);
    if (!path) {
      this.log.warn("[VideoPlayer] Invalid next episode ID:", this.episode.id);
      return;
    }

    this.log.debug("[VideoPlayer] Navigating to next episode:", path);
    this.window.location.href = path;
  }

  async preload() {
    if (!this.episode?.stream_url || this.preloader || this.destroyed) return;

    const url = this.episode.stream_url;
    this.log.debug("[VideoPlayer] Pre-loading next episode:", url);
    this.addPreconnect(url);

    if (this.streamType(url, this.episode.type) !== "hls" || !this.hlsSupported()) return;

    try {
      const Hls = await this.hlsLoader();
      if (this.destroyed || this.preloader) return;

      const preloader = new Hls({
        maxBufferLength: 5,
        maxBufferSize: 1 * 1024 * 1024,
        maxMaxBufferLength: 5,
        startLevel: -1,
        enableWorker: true,
        lowLatencyMode: false,
      });
      this.preloader = preloader;
      preloader.loadSource(url);

      preloader.on(Hls.Events.MANIFEST_PARSED, () => {
        if (!this.destroyed) this.log.debug("[VideoPlayer] Next episode manifest pre-loaded");
      });
      preloader.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal || this.preloader !== preloader) return;

        this.log.warn("[VideoPlayer] Next episode preload failed:", data.type);
        this.destroyPreloader();
      });
    } catch (error) {
      if (!this.destroyed) {
        this.log.debug("[VideoPlayer] Failed to preload next episode:", error.message);
      }
    }
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.clearCountdown();

    if (this.hideTimeout !== null) {
      this.scheduler.clearTimeout(this.hideTimeout);
      this.hideTimeout = null;
    }

    if (this.playButton) this.playButton.onclick = null;
    if (this.cancelButton) this.cancelButton.onclick = null;
    this.onPlay = null;
    this.destroyPreloader();
    this.preconnect?.remove?.();
    this.preconnect = null;
  }

  clearCountdown() {
    if (this.countdownInterval === null) return;
    this.scheduler.clearInterval(this.countdownInterval);
    this.countdownInterval = null;
  }

  destroyPreloader() {
    this.preloader?.destroy?.();
    this.preloader = null;
  }

  addPreconnect(url) {
    if (this.preconnect) return;

    try {
      const preconnect = this.document.createElement("link");
      preconnect.rel = "preconnect";
      preconnect.href = new URL(url).origin;
      preconnect.crossOrigin = "anonymous";
      this.document.head.appendChild(preconnect);
      this.preconnect = preconnect;
    } catch {
      // A malformed optional preload URL must not affect current playback.
    }
  }

  runSafely(operation, callback) {
    try {
      callback();
    } catch (error) {
      this.log.debug(`[VideoPlayer] ${operation} error:`, error.message);
    }
  }
}
