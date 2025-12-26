import Hls from "hls.js";
import mpegts from "mpegts.js";

const VideoPlayer = {
  mounted() {
    this.video = this.el.querySelector("video");
    this.streamUrl = this.el.dataset.streamUrl;
    this.proxyUrl = this.el.dataset.proxyUrl;
    this.startTime = Date.now();
    this.hls = null;
    this.mpegtsPlayer = null;
    this.errorContainer = null;
    this.retryCount = 0;
    this.maxRetries = 3;
    this.useProxy = true; // Start with proxy for .ts streams

    this.createErrorContainer();
    this.createLoadingIndicator();
    this.initPlayer();
    this.setupKeyboardShortcuts();
    this.trackWatchTime();
  },

  createErrorContainer() {
    this.errorContainer = document.createElement("div");
    this.errorContainer.className =
      "absolute inset-0 flex items-center justify-center bg-black/80 text-white text-center p-4 hidden";
    this.errorContainer.innerHTML = `
      <div>
        <svg class="w-16 h-16 mx-auto mb-4 text-error" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
        <p class="text-lg font-semibold mb-2">Unable to play stream</p>
        <p class="text-sm text-white/70 error-message"></p>
        <button class="btn btn-sm btn-primary mt-4 retry-btn">Retry</button>
      </div>
    `;
    this.el.style.position = "relative";
    this.el.appendChild(this.errorContainer);

    this.errorContainer.querySelector(".retry-btn").addEventListener("click", () => {
      this.hideError();
      this.retryCount = 0;
      this.initPlayer();
    });
  },

  createLoadingIndicator() {
    this.loadingIndicator = document.createElement("div");
    this.loadingIndicator.className =
      "absolute inset-0 flex items-center justify-center bg-black/50 text-white hidden";
    this.loadingIndicator.innerHTML = `
      <div class="text-center">
        <span class="loading loading-spinner loading-lg"></span>
        <p class="mt-2">Loading stream...</p>
      </div>
    `;
    this.el.appendChild(this.loadingIndicator);
  },

  showLoading() {
    this.loadingIndicator.classList.remove("hidden");
  },

  hideLoading() {
    this.loadingIndicator.classList.add("hidden");
  },

  showError(message) {
    this.hideLoading();
    this.errorContainer.querySelector(".error-message").textContent = message;
    this.errorContainer.classList.remove("hidden");
    this.video.classList.add("hidden");
  },

  hideError() {
    this.errorContainer.classList.add("hidden");
    this.video.classList.remove("hidden");
  },

  getStreamType(url) {
    if (!url) return "unknown";
    const lowercaseUrl = url.toLowerCase();

    // HLS streams
    if (lowercaseUrl.includes(".m3u8") || lowercaseUrl.includes("/hls/")) {
      return "hls";
    }
    // MPEG-TS streams
    if (lowercaseUrl.endsWith(".ts") || lowercaseUrl.includes(".ts?")) {
      return "ts";
    }
    // MP4 streams
    if (lowercaseUrl.includes(".mp4")) {
      return "mp4";
    }
    // FLV streams
    if (lowercaseUrl.includes(".flv")) {
      return "flv";
    }
    // Xtream Codes IPTV format (common pattern)
    if (lowercaseUrl.includes("/live/") && lowercaseUrl.includes("/")) {
      return "xtream";
    }
    return "unknown";
  },

  // Get the URL to use based on stream type and proxy availability
  getEffectiveUrl(streamType) {
    // Use proxy for MPEG-TS and Xtream streams (they benefit most from server-side caching)
    // HLS already has its own segmented caching mechanism
    const proxyableTypes = ["ts", "xtream", "unknown"];

    if (this.useProxy && this.proxyUrl && proxyableTypes.includes(streamType)) {
      console.log("Using proxy URL for", streamType, "stream");
      return this.proxyUrl;
    }

    console.log("Using direct URL for", streamType, "stream");
    return this.streamUrl;
  },

  cleanup() {
    if (this.hls) {
      this.hls.destroy();
      this.hls = null;
    }
    if (this.mpegtsPlayer) {
      this.mpegtsPlayer.pause();
      this.mpegtsPlayer.unload();
      this.mpegtsPlayer.detachMediaElement();
      this.mpegtsPlayer.destroy();
      this.mpegtsPlayer = null;
    }
    this.video.src = "";
    this.video.load();
  },

  initPlayer() {
    if (!this.streamUrl) {
      this.showError("No stream URL provided");
      return;
    }

    this.showLoading();
    console.log("Initializing player with URL:", this.streamUrl);
    console.log("Proxy URL available:", this.proxyUrl ? "yes" : "no");

    this.currentStreamType = this.getStreamType(this.streamUrl);
    console.log("Detected stream type:", this.currentStreamType);

    // Clean up previous instances
    this.cleanup();

    // Get the effective URL (proxy or direct based on stream type)
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);

    // Choose the best player based on stream type
    switch (this.currentStreamType) {
      case "hls":
        this.playWithHls();
        break;
      case "ts":
      case "xtream":
        // For .ts and Xtream streams, try mpegts.js first
        if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts();
        } else if (Hls.isSupported()) {
          // Fallback to HLS.js (some servers return HLS even with .ts extension)
          this.playWithHls();
        } else {
          this.playNative();
        }
        break;
      case "flv":
        if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts("flv");
        } else {
          this.showError("FLV playback not supported in this browser");
        }
        break;
      case "mp4":
        this.playNative();
        break;
      default:
        // Try HLS.js first for unknown streams, then mpegts, then native
        if (Hls.isSupported()) {
          this.playWithHls();
        } else if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts();
        } else {
          this.playNative();
        }
    }
  },

  playWithMpegts(type = "mpegts") {
    console.log("Playing with mpegts.js, type:", type, "url:", this.currentUrl);

    try {
      this.mpegtsPlayer = mpegts.createPlayer(
        {
          type: type, // 'mpegts', 'flv', 'm2ts', 'mse'
          isLive: true,
          url: this.currentUrl,
        },
        {
          enableWorker: true,
          enableStashBuffer: true,
          stashInitialSize: 512 * 1024, // 512KB initial buffer
          autoCleanupSourceBuffer: true,
          autoCleanupMaxBackwardDuration: 60, // Keep 60s of backward buffer
          autoCleanupMinBackwardDuration: 30, // Minimum 30s backward
          // Disable aggressive latency chasing to prevent rebuffering
          liveBufferLatencyChasing: false,
          // Increase buffer for smoother playback
          lazyLoad: false,
          lazyLoadMaxDuration: 60, // Buffer up to 60s
          lazyLoadRecoverDuration: 30,
          // Seek optimization
          accurateSeek: false,
          seekType: "range",
        }
      );

      this.mpegtsPlayer.attachMediaElement(this.video);
      this.mpegtsPlayer.load();

      this.mpegtsPlayer.on(mpegts.Events.LOADING_COMPLETE, () => {
        console.log("mpegts.js loading complete");
      });

      this.mpegtsPlayer.on(mpegts.Events.RECOVERED_EARLY_EOF, () => {
        console.log("mpegts.js recovered from early EOF");
      });

      this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
        console.log("mpegts.js media info:", info);
        this.hideLoading();
        this.hideError();
      });

      this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
        console.error("mpegts.js error:", errorType, errorDetail, errorInfo);

        // If using proxy and it failed, try direct URL first
        if (this.useProxy && this.currentUrl !== this.streamUrl) {
          console.log("Proxy failed, trying direct URL...");
          this.useProxy = false;
          this.currentUrl = this.streamUrl;
          this.cleanup();
          this.playWithMpegts();
          return;
        }

        if (this.retryCount < this.maxRetries) {
          this.retryCount++;
          console.log(`Retrying with different method (${this.retryCount}/${this.maxRetries})`);
          this.cleanup();

          // Try HLS.js as fallback
          if (Hls.isSupported()) {
            this.playWithHls();
          } else {
            this.playNative();
          }
        } else {
          this.showError(`Stream error: ${errorDetail || errorType}`);
        }
      });

      // Try to play
      this.video.play().catch((e) => {
        console.log("Autoplay prevented:", e);
        if (e.name === "NotAllowedError") {
          this.hideLoading();
          this.showPlayButton();
        }
      });

      // Handle successful playback
      this.video.addEventListener(
        "playing",
        () => {
          this.hideLoading();
          this.hideError();
        },
        { once: true }
      );
    } catch (e) {
      console.error("mpegts.js initialization error:", e);
      // Fallback to HLS.js
      if (Hls.isSupported()) {
        this.playWithHls();
      } else {
        this.playNative();
      }
    }
  },

  playWithHls() {
    // For HLS, always use direct URL - HLS.js handles its own buffering
    const hlsUrl = this.currentStreamType === "hls" ? this.streamUrl : this.currentUrl;
    console.log("Playing with HLS.js, url:", hlsUrl);

    if (!Hls.isSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.showError("HLS not supported in this browser");
      }
      return;
    }

    this.hls = new Hls({
      enableWorker: true,
      // Disable low latency mode for smoother playback
      lowLatencyMode: false,
      // Increase buffer sizes to reduce rebuffering
      backBufferLength: 120, // 2 minutes of back buffer
      maxBufferLength: 60, // Buffer up to 60 seconds ahead
      maxMaxBufferLength: 120, // Max 2 minutes buffer
      maxBufferSize: 60 * 1000 * 1000, // 60MB max buffer
      maxBufferHole: 0.5, // Allow 0.5s gaps without rebuffering
      // Start with auto quality
      startLevel: -1,
      // ABR settings for stability
      abrEwmaDefaultEstimate: 500000, // Start with 500kbps estimate
      abrBandWidthFactor: 0.8, // Conservative bandwidth factor
      abrBandWidthUpFactor: 0.5, // Slower upward switches
      // Fragment loading settings
      fragLoadingTimeOut: 20000,
      fragLoadingMaxRetry: 6,
      fragLoadingRetryDelay: 1000,
      // Level loading settings
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      levelLoadingRetryDelay: 1000,
      xhrSetup: (xhr) => {
        xhr.withCredentials = false;
      },
    });

    this.hls.loadSource(hlsUrl);
    this.hls.attachMedia(this.video);

    this.hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
      console.log("HLS manifest parsed, levels:", data.levels.length);
      this.hideLoading();
      this.hideError();
      this.video.play().catch((e) => {
        console.log("Autoplay prevented:", e);
        this.showPlayButton();
      });
    });

    this.hls.on(Hls.Events.ERROR, (_event, data) => {
      console.error("HLS error:", data);

      if (data.fatal) {
        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            if (
              data.details === Hls.ErrorDetails.MANIFEST_LOAD_ERROR ||
              data.details === Hls.ErrorDetails.MANIFEST_PARSING_ERROR
            ) {
              // Not an HLS stream, try mpegts.js
              if (this.retryCount < this.maxRetries && mpegts.getFeatureList().mseLivePlayback) {
                this.retryCount++;
                console.log("HLS failed, trying mpegts.js...");
                this.cleanup();
                this.playWithMpegts();
              } else {
                this.showError("Unable to load stream - server may be unavailable");
              }
            } else {
              console.log("Network error, trying to recover...");
              this.hls.startLoad();
            }
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            console.log("Media error, trying to recover...");
            this.hls.recoverMediaError();
            break;
          default:
            if (this.retryCount < this.maxRetries) {
              this.retryCount++;
              this.cleanup();
              if (mpegts.getFeatureList().mseLivePlayback) {
                this.playWithMpegts();
              } else {
                this.playNative();
              }
            } else {
              this.showError("Playback error - stream format may not be supported");
            }
            break;
        }
      }
    });
  },

  playNative() {
    console.log("Playing with native video element, url:", this.currentUrl);
    this.video.src = this.currentUrl;

    const playHandler = () => {
      console.log("Native playback started");
      this.hideLoading();
      this.hideError();
      this.video.removeEventListener("playing", playHandler);
    };

    const errorHandler = () => {
      const error = this.video.error;
      let message = "Stream playback failed";

      if (error) {
        switch (error.code) {
          case MediaError.MEDIA_ERR_ABORTED:
            message = "Playback aborted";
            break;
          case MediaError.MEDIA_ERR_NETWORK:
            message = "Network error - check your connection";
            break;
          case MediaError.MEDIA_ERR_DECODE:
            message = "Stream format not supported";
            break;
          case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED:
            message = "Stream format not supported by browser";
            break;
        }
      }

      this.showError(message);
      this.video.removeEventListener("error", errorHandler);
    };

    this.video.addEventListener("playing", playHandler);
    this.video.addEventListener("error", errorHandler);
    this.video.addEventListener("loadedmetadata", () => this.hideLoading(), { once: true });

    this.video.play().catch((e) => {
      console.log("Native autoplay prevented:", e);
      this.hideLoading();
      if (e.name === "NotAllowedError") {
        this.showPlayButton();
      } else {
        this.showError("Failed to start playback: " + e.message);
      }
    });
  },

  showPlayButton() {
    // Remove existing overlay if any
    const existing = this.el.querySelector(".play-overlay");
    if (existing) existing.remove();

    const playOverlay = document.createElement("div");
    playOverlay.className =
      "play-overlay absolute inset-0 flex items-center justify-center bg-black/50 cursor-pointer";
    playOverlay.innerHTML = `
      <svg class="w-24 h-24 text-white opacity-80 hover:opacity-100 transition-opacity" fill="currentColor" viewBox="0 0 24 24">
        <path d="M8 5v14l11-7z" />
      </svg>
    `;
    playOverlay.addEventListener("click", () => {
      playOverlay.remove();
      this.video.play().catch(console.error);
    });
    this.el.appendChild(playOverlay);
  },

  setupKeyboardShortcuts() {
    this.keyHandler = (e) => {
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
        return;
      }

      switch (e.key) {
        case "f":
        case "F":
          this.toggleFullscreen();
          break;
        case " ":
          e.preventDefault();
          this.togglePlayPause();
          break;
        case "m":
        case "M":
          this.toggleMute();
          break;
        case "ArrowUp":
          e.preventDefault();
          this.adjustVolume(0.1);
          break;
        case "ArrowDown":
          e.preventDefault();
          this.adjustVolume(-0.1);
          break;
      }
    };

    document.addEventListener("keydown", this.keyHandler);
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      this.video.requestFullscreen();
    }
  },

  togglePlayPause() {
    if (this.video.paused) {
      this.video.play();
    } else {
      this.video.pause();
    }
  },

  toggleMute() {
    this.video.muted = !this.video.muted;
  },

  adjustVolume(delta) {
    this.video.volume = Math.max(0, Math.min(1, this.video.volume + delta));
  },

  trackWatchTime() {
    this.watchInterval = setInterval(() => {
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      if (duration > 0 && duration % 30 === 0) {
        this.pushEvent("update_watch_time", { duration });
      }
    }, 1000);
  },

  destroyed() {
    this.cleanup();

    if (this.keyHandler) {
      document.removeEventListener("keydown", this.keyHandler);
    }

    if (this.watchInterval) {
      clearInterval(this.watchInterval);
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      if (duration > 0) {
        this.pushEvent("update_watch_time", { duration });
      }
    }
  },
};

export default VideoPlayer;
