import Hls from "hls.js";
import mpegts from "mpegts.js";
import {
  ContentType,
  selectStreamingMode,
  getStreamingConfig,
} from "../lib/streaming_config";
import { NetworkMonitor } from "../lib/network_monitor";

/**
 * Enhanced VideoPlayer Hook for Streamix
 *
 * Features:
 * - Multi-codec support (HLS, MPEG-TS, FLV, MP4)
 * - Adaptive streaming with dynamic mode switching
 * - Quality selection (auto + manual levels)
 * - Audio/subtitle track selection
 * - Picture-in-Picture support
 * - Network monitoring with automatic adaptation
 * - Progress tracking for VOD content
 */
const VideoPlayer = {
  mounted() {
    this.initializeState();
    this.createUI();
    this.initPlayer();
    this.setupEventListeners();
    this.setupNetworkMonitor();
    this.setupKeyboardShortcuts();
    this.trackWatchTime();
  },

  initializeState() {
    // DOM elements
    this.video = this.el.querySelector("video");

    // Stream configuration
    this.streamUrl = this.el.dataset.streamUrl;
    this.proxyUrl = this.el.dataset.proxyUrl;
    this.contentType = this.el.dataset.contentType || "live"; // 'live' or 'vod'
    this.contentId = this.el.dataset.contentId;
    this.initialMode = this.el.dataset.streamingMode || null;

    // Player instances
    this.hls = null;
    this.mpegtsPlayer = null;

    // Streaming state
    this.streamingMode = this.initialMode ||
      selectStreamingMode(
        this.contentType === "live" ? ContentType.LIVE : ContentType.VOD,
        "good"
      );
    this.currentStreamType = null;
    this.currentUrl = null;

    // Quality state
    this.manualQuality = null; // null = auto, number = level index
    this.availableQualities = [];

    // Track state
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.selectedAudioTrack = 0;
    this.selectedSubtitleTrack = -1; // -1 = off

    // Retry/fallback state
    this.retryCount = 0;
    this.maxRetries = 3;
    this.useProxy = true;

    // Timing
    this.startTime = Date.now();
    this.lastProgressReport = 0;

    // PiP state
    this.pipActive = false;

    // Network monitor
    this.networkMonitor = null;
  },

  createUI() {
    this.el.style.position = "relative";
    this.createErrorContainer();
    // Track whether we're using native controls to avoid duplicate loaders
    this.hasNativeControls = this.video?.hasAttribute("controls");
    this.createLoadingIndicator();
  },

  createErrorContainer() {
    this.errorContainer = document.createElement("div");
    this.errorContainer.className =
      "absolute inset-0 flex items-center justify-center bg-black/80 text-white text-center p-4 hidden z-20";
    this.errorContainer.innerHTML = `
      <div>
        <svg class="w-16 h-16 mx-auto mb-4 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
        <p class="text-lg font-semibold mb-2">Não foi possível reproduzir</p>
        <p class="text-sm text-white/70 error-message"></p>
        <button class="mt-4 px-4 py-2 bg-brand hover:bg-brand/90 text-white text-sm font-medium rounded-lg transition-colors retry-btn">Tentar novamente</button>
      </div>
    `;
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
      "absolute inset-0 flex items-center justify-center bg-black/50 text-white hidden z-20";
    this.loadingIndicator.innerHTML = `
      <div class="text-center">
        <svg class="w-12 h-12 mx-auto animate-spin text-white" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <p class="mt-3">Carregando...</p>
      </div>
    `;
    this.el.appendChild(this.loadingIndicator);
  },

  showLoading() {
    // Skip custom loading indicator when native controls are present
    // to avoid duplicate loaders (browser already shows loading state)
    if (this.hasNativeControls) return;
    this.loadingIndicator?.classList.remove("hidden");
  },

  hideLoading() {
    this.loadingIndicator?.classList.add("hidden");
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

  // ============================================
  // Network Monitoring
  // ============================================

  setupNetworkMonitor() {
    this.networkMonitor = new NetworkMonitor({
      onQualityChange: (newQuality, oldQuality, stats) => {
        console.log(`Network quality changed: ${oldQuality} -> ${newQuality}`, stats);

        // Only adapt if using auto quality and content is live
        if (this.manualQuality === null && this.contentType === "live") {
          const newMode = selectStreamingMode(ContentType.LIVE, newQuality);
          if (newMode !== this.streamingMode) {
            this.switchStreamingMode(newMode);
          }
        }
      },
    });

    this.networkMonitor.start();
  },

  // ============================================
  // Streaming Mode Management
  // ============================================

  switchStreamingMode(newMode) {
    if (newMode === this.streamingMode) return;

    console.log(`Switching streaming mode: ${this.streamingMode} -> ${newMode}`);
    this.streamingMode = newMode;

    // Apply new configuration to active player
    if (this.hls) {
      const config = getStreamingConfig(newMode);
      Object.keys(config.hls).forEach((key) => {
        if (key in this.hls.config) {
          this.hls.config[key] = config.hls[key];
        }
      });
    }

    // Notify LiveView
    this.pushEvent("streaming_mode_changed", {
      mode: newMode,
      config: getStreamingConfig(newMode).name,
    });
  },

  // ============================================
  // Quality Selection
  // ============================================

  setQuality(levelIndex) {
    if (!this.hls) return;

    this.hls.currentLevel = levelIndex;
    this.manualQuality = levelIndex === -1 ? null : levelIndex;

    const quality = levelIndex === -1
      ? "auto"
      : this.availableQualities[levelIndex]?.label || `Level ${levelIndex}`;

    this.pushEvent("quality_changed", { quality, level: levelIndex });
  },

  getAvailableQualities() {
    if (!this.hls || !this.hls.levels) return [];

    return this.hls.levels.map((level, index) => ({
      index,
      height: level.height,
      width: level.width,
      bitrate: level.bitrate,
      label: level.height ? `${level.height}p` : `${Math.round(level.bitrate / 1000)}k`,
    }));
  },

  updateQualityList() {
    this.availableQualities = this.getAvailableQualities();

    // Update DOM with quality options
    const qualityContainer = this.el.querySelector("#quality-options");
    if (qualityContainer && this.availableQualities.length > 0) {
      const currentLevel = this.hls?.currentLevel ?? -1;

      qualityContainer.innerHTML = `
        <button type="button" data-level="-1"
          class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors quality-option">
          <span>Automático</span>
          <svg class="size-4 ${currentLevel === -1 ? "" : "invisible"}" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
          </svg>
        </button>
        ${this.availableQualities
          .map(
            (q) => `
          <button type="button" data-level="${q.index}"
            class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors quality-option">
            <span>${q.label}</span>
            <svg class="size-4 ${currentLevel === q.index ? "" : "invisible"}" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
            </svg>
          </button>
        `
          )
          .join("")}
      `;

      // Add click handlers
      qualityContainer.querySelectorAll(".quality-option").forEach((btn) => {
        btn.addEventListener("click", () => {
          const level = parseInt(btn.dataset.level, 10);
          this.setQuality(level);
          this.updateQualityCheckmarks(level);
        });
      });
    }

    // Notify LiveView of available qualities
    this.pushEvent("qualities_available", {
      qualities: [{ index: -1, label: "Automático" }, ...this.availableQualities],
      current: this.hls?.currentLevel ?? -1,
    });
  },

  updateQualityCheckmarks(selectedLevel) {
    const container = this.el.querySelector("#quality-options");
    if (!container) return;

    container.querySelectorAll(".quality-option svg").forEach((svg) => {
      const btn = svg.closest("button");
      const level = parseInt(btn.dataset.level, 10);
      svg.classList.toggle("invisible", level !== selectedLevel);
    });
  },

  // ============================================
  // Audio Track Selection
  // ============================================

  setAudioTrack(trackIndex) {
    if (!this.hls) return;

    this.hls.audioTrack = trackIndex;
    this.selectedAudioTrack = trackIndex;

    const track = this.audioTracks[trackIndex];
    this.pushEvent("audio_track_changed", {
      track: trackIndex,
      label: track?.name || track?.lang || `Track ${trackIndex}`,
    });
  },

  updateAudioTracks() {
    if (!this.hls) return;

    this.audioTracks = this.hls.audioTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Áudio ${index + 1}`,
    }));

    // Update DOM with audio options
    const audioContainer = this.el.querySelector("#audio-options");
    if (audioContainer && this.audioTracks.length > 0) {
      const currentTrack = this.hls.audioTrack;

      audioContainer.innerHTML = this.audioTracks
        .map(
          (t) => `
        <button type="button" data-track="${t.index}"
          class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors audio-option">
          <span>${t.label}</span>
          <svg class="size-4 ${currentTrack === t.index ? "" : "invisible"}" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
          </svg>
        </button>
      `
        )
        .join("");

      // Add click handlers
      audioContainer.querySelectorAll(".audio-option").forEach((btn) => {
        btn.addEventListener("click", () => {
          const track = parseInt(btn.dataset.track, 10);
          this.setAudioTrack(track);
          this.updateAudioCheckmarks(track);
        });
      });
    } else if (audioContainer && this.audioTracks.length === 0) {
      audioContainer.innerHTML = `<div class="px-4 py-2 text-sm text-white/50">Padrão</div>`;
    }

    this.pushEvent("audio_tracks_available", {
      tracks: this.audioTracks,
      current: this.hls.audioTrack,
    });
  },

  updateAudioCheckmarks(selectedTrack) {
    const container = this.el.querySelector("#audio-options");
    if (!container) return;

    container.querySelectorAll(".audio-option svg").forEach((svg) => {
      const btn = svg.closest("button");
      const track = parseInt(btn.dataset.track, 10);
      svg.classList.toggle("invisible", track !== selectedTrack);
    });
  },

  // ============================================
  // Subtitle Track Selection
  // ============================================

  setSubtitleTrack(trackIndex) {
    if (!this.hls) return;

    this.hls.subtitleTrack = trackIndex; // -1 to disable
    this.selectedSubtitleTrack = trackIndex;

    const track = trackIndex >= 0 ? this.subtitleTracks[trackIndex] : null;
    this.pushEvent("subtitle_track_changed", {
      track: trackIndex,
      label: track?.name || track?.lang || (trackIndex === -1 ? "Desativado" : `Faixa ${trackIndex}`),
    });
  },

  updateSubtitleTracks() {
    if (!this.hls) return;

    this.subtitleTracks = this.hls.subtitleTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Legenda ${index + 1}`,
    }));

    // Update DOM with subtitle options
    const subtitleContainer = this.el.querySelector("#subtitle-options");
    if (subtitleContainer) {
      const currentTrack = this.hls.subtitleTrack;

      subtitleContainer.innerHTML = `
        <button type="button" data-track="-1"
          class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors subtitle-option">
          <span>Desativadas</span>
          <svg class="size-4 ${currentTrack === -1 ? "" : "invisible"}" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
          </svg>
        </button>
        ${this.subtitleTracks
          .map(
            (t) => `
          <button type="button" data-track="${t.index}"
            class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors subtitle-option">
            <span>${t.label}</span>
            <svg class="size-4 ${currentTrack === t.index ? "" : "invisible"}" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
            </svg>
          </button>
        `
          )
          .join("")}
      `;

      // Add click handlers
      subtitleContainer.querySelectorAll(".subtitle-option").forEach((btn) => {
        btn.addEventListener("click", () => {
          const track = parseInt(btn.dataset.track, 10);
          this.setSubtitleTrack(track);
          this.updateSubtitleCheckmarks(track);
        });
      });
    }

    this.pushEvent("subtitle_tracks_available", {
      tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
      current: this.hls.subtitleTrack,
    });
  },

  updateSubtitleCheckmarks(selectedTrack) {
    const container = this.el.querySelector("#subtitle-options");
    if (!container) return;

    container.querySelectorAll(".subtitle-option svg").forEach((svg) => {
      const btn = svg.closest("button");
      const track = parseInt(btn.dataset.track, 10);
      svg.classList.toggle("invisible", track !== selectedTrack);
    });
  },

  // ============================================
  // Picture-in-Picture
  // ============================================

  async togglePiP() {
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
        this.pipActive = false;
      } else if (document.pictureInPictureEnabled && this.video) {
        await this.video.requestPictureInPicture();
        this.pipActive = true;
      }

      this.pushEvent("pip_toggled", { active: this.pipActive });
    } catch (error) {
      console.error("PiP error:", error);
      this.pushEvent("pip_error", { message: error.message });
    }
  },

  isPiPSupported() {
    return document.pictureInPictureEnabled && !this.video?.disablePictureInPicture;
  },

  // ============================================
  // Event Listeners
  // ============================================

  setupEventListeners() {
    // ============================================
    // DOM Custom Events from UI Controls
    // ============================================
    this.el.addEventListener("player:toggle-play", () => this.togglePlayPause());
    this.el.addEventListener("player:toggle-mute", () => this.toggleMute());
    this.el.addEventListener("player:toggle-fullscreen", () => this.toggleFullscreen());
    this.el.addEventListener("player:toggle-pip", () => this.togglePiP());
    this.el.addEventListener("player:set-speed", (e) => {
      const speed = parseFloat(e.detail?.speed || 1);
      this.setPlaybackRate(speed);
    });

    // ============================================
    // Mobile Touch Support
    // ============================================
    this.setupMobileControls();

    // Volume slider input
    const volumeSlider = this.el.querySelector("#volume-slider");
    if (volumeSlider) {
      volumeSlider.addEventListener("input", (e) => {
        const volume = parseInt(e.target.value, 10) / 100;
        this.video.volume = volume;
        if (volume > 0 && this.video.muted) {
          this.video.muted = false;
        }
      });
    }

    // ============================================
    // Video Element Events for UI Updates
    // ============================================
    this.video?.addEventListener("play", () => this.updatePlayPauseUI(false));
    this.video?.addEventListener("pause", () => this.updatePlayPauseUI(true));
    this.video?.addEventListener("volumechange", () => this.updateVolumeUI());
    this.video?.addEventListener("timeupdate", () => this.updateTimeUI());
    this.video?.addEventListener("loadedmetadata", () => this.updateTimeUI());
    this.video?.addEventListener("ratechange", () => this.updateSpeedUI());

    // Fullscreen change events
    document.addEventListener("fullscreenchange", () => this.updateFullscreenUI());
    document.addEventListener("webkitfullscreenchange", () => this.updateFullscreenUI());

    // ============================================
    // Listen for commands from LiveView
    // ============================================
    this.handleEvent("set_quality", ({ level }) => {
      this.setQuality(level);
    });

    this.handleEvent("set_audio_track", ({ track }) => {
      this.setAudioTrack(track);
    });

    this.handleEvent("set_subtitle_track", ({ track }) => {
      this.setSubtitleTrack(track);
    });

    this.handleEvent("toggle_pip", () => {
      this.togglePiP();
    });

    this.handleEvent("set_streaming_mode", ({ mode }) => {
      this.switchStreamingMode(mode);
    });

    this.handleEvent("seek", ({ time }) => {
      if (this.video) {
        this.video.currentTime = time;
      }
    });

    this.handleEvent("set_playback_rate", ({ rate }) => {
      this.setPlaybackRate(rate);
    });

    // ============================================
    // PiP events from video element
    // ============================================
    this.video?.addEventListener("enterpictureinpicture", () => {
      this.pipActive = true;
      this.pushEvent("pip_toggled", { active: true });
    });

    this.video?.addEventListener("leavepictureinpicture", () => {
      this.pipActive = false;
      this.pushEvent("pip_toggled", { active: false });
    });

    // ============================================
    // Progress tracking for VOD
    // ============================================
    if (this.contentType === "vod") {
      this.video?.addEventListener("timeupdate", () => {
        this.reportProgress();
      });

      this.video?.addEventListener("durationchange", () => {
        if (this.video.duration && isFinite(this.video.duration)) {
          this.pushEvent("duration_available", {
            duration: Math.floor(this.video.duration),
          });
        }
      });
    }

    // ============================================
    // Buffer health monitoring
    // ============================================
    this.video?.addEventListener("waiting", () => {
      this.pushEvent("buffering", { buffering: true });
    });

    this.video?.addEventListener("playing", () => {
      this.pushEvent("buffering", { buffering: false });
      this.hideLoading();
      this.hideError();
    });
  },

  // ============================================
  // UI State Update Functions
  // ============================================

  updatePlayPauseUI(paused) {
    const playIcon = this.el.querySelector(".play-icon");
    const pauseIcon = this.el.querySelector(".pause-icon");
    const centerPlay = this.el.querySelector("#center-play");

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
  },

  updateVolumeUI() {
    const volumeOnIcon = this.el.querySelector(".volume-on-icon");
    const volumeOffIcon = this.el.querySelector(".volume-off-icon");
    const volumeSlider = this.el.querySelector("#volume-slider");

    if (volumeOnIcon && volumeOffIcon) {
      if (this.video.muted || this.video.volume === 0) {
        volumeOnIcon.classList.add("hidden");
        volumeOffIcon.classList.remove("hidden");
      } else {
        volumeOnIcon.classList.remove("hidden");
        volumeOffIcon.classList.add("hidden");
      }
    }

    if (volumeSlider) {
      volumeSlider.value = this.video.muted ? 0 : Math.round(this.video.volume * 100);
    }
  },

  updateTimeUI() {
    if (!this.video) return;

    const currentTimeEl = this.el.querySelector("#current-time");
    const durationEl = this.el.querySelector("#duration");

    if (currentTimeEl) {
      currentTimeEl.textContent = this.formatTime(this.video.currentTime);
    }

    if (durationEl && this.video.duration && isFinite(this.video.duration)) {
      durationEl.textContent = this.formatTime(this.video.duration);
    }
  },

  updateSpeedUI() {
    const speedLabel = this.el.querySelector("#speed-label");
    if (speedLabel && this.video) {
      speedLabel.textContent = `${this.video.playbackRate}x`;
    }
  },

  updateFullscreenUI() {
    const expandIcon = this.el.querySelector(".expand-icon");
    const collapseIcon = this.el.querySelector(".collapse-icon");
    const isFullscreen = !!document.fullscreenElement;

    if (expandIcon && collapseIcon) {
      if (isFullscreen) {
        expandIcon.classList.add("hidden");
        collapseIcon.classList.remove("hidden");
      } else {
        expandIcon.classList.remove("hidden");
        collapseIcon.classList.add("hidden");
      }
    }
  },

  formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) return "0:00";

    const hrs = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);

    if (hrs > 0) {
      return `${hrs}:${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
    }
    return `${mins}:${secs.toString().padStart(2, "0")}`;
  },

  setPlaybackRate(rate) {
    if (this.video) {
      this.video.playbackRate = rate;
      this.pushEvent("playback_rate_changed", { rate });
    }
  },

  reportProgress() {
    if (!this.video || !this.video.duration) return;

    const currentTime = Math.floor(this.video.currentTime);
    const duration = Math.floor(this.video.duration);

    // Throttle updates to every 10 seconds
    if (Math.abs(currentTime - this.lastProgressReport) >= 10) {
      this.lastProgressReport = currentTime;

      this.pushEvent("progress_update", {
        current_time: currentTime,
        duration: duration,
        percent: Math.round((currentTime / duration) * 100),
      });
    }
  },

  // ============================================
  // Stream Type Detection
  // ============================================

  getStreamType(url) {
    if (!url) return "unknown";
    const lowercaseUrl = url.toLowerCase();

    if (lowercaseUrl.includes(".m3u8") || lowercaseUrl.includes("/hls/")) {
      return "hls";
    }
    if (lowercaseUrl.endsWith(".ts") || lowercaseUrl.includes(".ts?")) {
      return "ts";
    }
    if (lowercaseUrl.includes(".mp4")) {
      return "mp4";
    }
    if (lowercaseUrl.includes(".flv")) {
      return "flv";
    }
    if (lowercaseUrl.includes("/live/") && lowercaseUrl.includes("/")) {
      return "xtream";
    }
    return "unknown";
  },

  getEffectiveUrl(streamType) {
    // Always use proxy for HTTP URLs when on HTTPS to avoid Mixed Content blocking
    const isHttpUrl = this.streamUrl?.startsWith("http://");
    const isHttpsPage = window.location.protocol === "https:";

    // Force proxy for ALL HTTP streams when on HTTPS (mixed content blocking)
    if (isHttpUrl && isHttpsPage && this.proxyUrl) {
      console.log("Using proxy URL for", streamType, "stream (HTTP -> HTTPS proxy required)");
      return this.proxyUrl;
    }

    // For same-protocol, proxy specific stream types that benefit from it
    const proxyableTypes = ["ts", "xtream", "unknown"];
    if (this.useProxy && this.proxyUrl && proxyableTypes.includes(streamType)) {
      console.log("Using proxy URL for", streamType, "stream");
      return this.proxyUrl;
    }

    console.log("Using direct URL for", streamType, "stream");
    return this.streamUrl;
  },

  // ============================================
  // Player Initialization
  // ============================================

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
      this.showError("URL do stream não fornecida");
      return;
    }

    this.showLoading();
    console.log("Initializing player with URL:", this.streamUrl);
    console.log("Streaming mode:", this.streamingMode);
    console.log("Content type:", this.contentType);

    this.currentStreamType = this.getStreamType(this.streamUrl);
    console.log("Detected stream type:", this.currentStreamType);

    this.cleanup();
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);

    // Notify LiveView of player initialization
    this.pushEvent("player_initializing", {
      stream_type: this.currentStreamType,
      streaming_mode: this.streamingMode,
      pip_supported: this.isPiPSupported(),
    });

    switch (this.currentStreamType) {
      case "hls":
        this.playWithHls();
        break;
      case "ts":
      case "xtream":
        if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts();
        } else if (Hls.isSupported()) {
          this.playWithHls();
        } else {
          this.playNative();
        }
        break;
      case "flv":
        if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts("flv");
        } else {
          this.showError("Reprodução FLV não suportada neste navegador");
        }
        break;
      case "mp4":
        this.playNative();
        break;
      default:
        if (Hls.isSupported()) {
          this.playWithHls();
        } else if (mpegts.getFeatureList().mseLivePlayback) {
          this.playWithMpegts();
        } else {
          this.playNative();
        }
    }
  },

  playWithHls() {
    // Always use currentUrl which properly handles HTTP->HTTPS proxy
    const hlsUrl = this.currentUrl;
    console.log("Playing with HLS.js, url:", hlsUrl);

    if (!Hls.isSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.showError("HLS não suportado neste navegador");
      }
      return;
    }

    // Get streaming profile configuration
    const config = getStreamingConfig(this.streamingMode);

    this.hls = new Hls({
      ...config.hls,
      xhrSetup: (xhr) => {
        xhr.withCredentials = false;
      },
    });

    this.hls.loadSource(hlsUrl);
    this.hls.attachMedia(this.video);

    // Track bandwidth for network monitoring
    this.hls.on(Hls.Events.FRAG_LOADED, (_event, data) => {
      if (data.frag.stats.loaded && data.frag.stats.loading.end) {
        const loadTime = data.frag.stats.loading.end - data.frag.stats.loading.start;
        const bandwidth = (data.frag.stats.loaded * 8000) / loadTime; // bps
        this.networkMonitor?.addSample(bandwidth);
      }
    });

    this.hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
      console.log("HLS manifest parsed, levels:", data.levels.length);
      this.hideLoading();
      this.hideError();

      // Update available qualities
      this.updateQualityList();
      this.updateAudioTracks();
      this.updateSubtitleTracks();

      this.video.play().catch((e) => {
        console.log("Autoplay prevented:", e);
        this.showPlayButton();
      });
    });

    this.hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
      // Notify of quality switch
      const level = this.hls.levels[data.level];
      this.pushEvent("quality_switched", {
        level: data.level,
        height: level?.height,
        bitrate: level?.bitrate,
        auto: this.manualQuality === null,
      });
    });

    this.hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, () => {
      this.updateAudioTracks();
    });

    this.hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, () => {
      this.updateSubtitleTracks();
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
              if (this.retryCount < this.maxRetries && mpegts.getFeatureList().mseLivePlayback) {
                this.retryCount++;
                console.log("HLS failed, trying mpegts.js...");
                this.cleanup();
                this.playWithMpegts();
              } else {
                this.showError("Não foi possível carregar - servidor indisponível");
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
              this.showError("Erro de reprodução - formato não suportado");
            }
            break;
        }
      }
    });
  },

  playWithMpegts(type = "mpegts") {
    console.log("Playing with mpegts.js, type:", type, "url:", this.currentUrl);

    try {
      const config = getStreamingConfig(this.streamingMode);

      this.mpegtsPlayer = mpegts.createPlayer(
        {
          type: type,
          isLive: this.contentType === "live",
          url: this.currentUrl,
        },
        config.mpegts
      );

      this.mpegtsPlayer.attachMediaElement(this.video);
      this.mpegtsPlayer.load();

      this.mpegtsPlayer.on(mpegts.Events.STATISTICS_INFO, (info) => {
        if (info.speed) {
          this.networkMonitor?.addSample(info.speed * 1000); // KB/s to bps
        }
      });

      this.mpegtsPlayer.on(mpegts.Events.MEDIA_INFO, (info) => {
        console.log("mpegts.js media info:", info);
        this.hideLoading();
        this.hideError();
      });

      this.mpegtsPlayer.on(mpegts.Events.ERROR, (errorType, errorDetail, errorInfo) => {
        console.error("mpegts.js error:", errorType, errorDetail, errorInfo);

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

          if (Hls.isSupported()) {
            this.playWithHls();
          } else {
            this.playNative();
          }
        } else {
          this.showError(`Erro no stream: ${errorDetail || errorType}`);
        }
      });

      this.video.play().catch((e) => {
        console.log("Autoplay prevented:", e);
        if (e.name === "NotAllowedError") {
          this.hideLoading();
          this.showPlayButton();
        }
      });

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
      if (Hls.isSupported()) {
        this.playWithHls();
      } else {
        this.playNative();
      }
    }
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
      let message = "Falha na reprodução";

      if (error) {
        switch (error.code) {
          case MediaError.MEDIA_ERR_ABORTED:
            message = "Reprodução cancelada";
            break;
          case MediaError.MEDIA_ERR_NETWORK:
            message = "Erro de rede - verifique sua conexão";
            break;
          case MediaError.MEDIA_ERR_DECODE:
            message = "Formato não suportado";
            break;
          case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED:
            message = "Formato não suportado pelo navegador";
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
        this.showError("Falha ao iniciar reprodução: " + e.message);
      }
    });
  },

  showPlayButton() {
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

  // ============================================
  // Mobile Touch Controls
  // ============================================

  setupMobileControls() {
    const controls = this.el.querySelector("#player-controls");
    if (!controls) return;

    // Track touch state
    this.controlsVisible = true;
    this.controlsTimeout = null;
    this.lastTapTime = 0;

    // Detect mobile/touch device
    this.isTouchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;

    if (this.isTouchDevice) {
      // Tap on video to toggle controls and play/pause
      this.video.addEventListener("click", (e) => {
        e.preventDefault();
        const now = Date.now();
        const timeSinceLastTap = now - this.lastTapTime;

        if (timeSinceLastTap < 300) {
          // Double tap - toggle fullscreen
          this.toggleFullscreen();
        } else {
          // Single tap - toggle controls visibility
          this.toggleControlsVisibility();
        }

        this.lastTapTime = now;
      });

      // Start with controls visible, then auto-hide
      this.showControls();
      this.scheduleHideControls();

      // Keep controls visible when interacting with them
      controls.addEventListener("touchstart", () => {
        this.clearHideControlsTimeout();
      });

      controls.addEventListener("touchend", () => {
        this.scheduleHideControls();
      });
    }

    // Mouse movement shows controls (desktop)
    this.el.addEventListener("mousemove", () => {
      if (!this.isTouchDevice) {
        this.showControls();
        this.scheduleHideControls();
      }
    });

    // Hide controls when video plays
    this.video.addEventListener("play", () => {
      this.scheduleHideControls();
    });

    // Show controls when video pauses
    this.video.addEventListener("pause", () => {
      this.showControls();
      this.clearHideControlsTimeout();
    });
  },

  toggleControlsVisibility() {
    if (this.controlsVisible) {
      this.hideControls();
    } else {
      this.showControls();
      this.scheduleHideControls();
    }
  },

  showControls() {
    const controls = this.el.querySelector("#player-controls");
    if (controls) {
      controls.classList.remove("controls-hidden");
      controls.style.opacity = "1";
      this.controlsVisible = true;
    }
  },

  hideControls() {
    const controls = this.el.querySelector("#player-controls");
    if (controls && !this.video.paused) {
      controls.classList.add("controls-hidden");
      controls.style.opacity = "0";
      this.controlsVisible = false;
    }
  },

  scheduleHideControls() {
    this.clearHideControlsTimeout();
    this.controlsTimeout = setTimeout(() => {
      if (!this.video.paused) {
        this.hideControls();
      }
    }, 3000);
  },

  clearHideControlsTimeout() {
    if (this.controlsTimeout) {
      clearTimeout(this.controlsTimeout);
      this.controlsTimeout = null;
    }
  },

  // ============================================
  // Keyboard Shortcuts
  // ============================================

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
        case "p":
        case "P":
          if (this.isPiPSupported()) {
            this.togglePiP();
          }
          break;
        case "ArrowUp":
          e.preventDefault();
          this.adjustVolume(0.1);
          break;
        case "ArrowDown":
          e.preventDefault();
          this.adjustVolume(-0.1);
          break;
        case "ArrowLeft":
          if (this.contentType === "vod") {
            e.preventDefault();
            this.seek(-10);
          }
          break;
        case "ArrowRight":
          if (this.contentType === "vod") {
            e.preventDefault();
            this.seek(10);
          }
          break;
      }
    };

    document.addEventListener("keydown", this.keyHandler);
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else {
      this.el.requestFullscreen?.() || this.video.requestFullscreen?.();
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
    this.pushEvent("mute_toggled", { muted: this.video.muted });
  },

  adjustVolume(delta) {
    this.video.volume = Math.max(0, Math.min(1, this.video.volume + delta));
    this.pushEvent("volume_changed", { volume: Math.round(this.video.volume * 100) });
  },

  seek(seconds) {
    if (this.video.duration) {
      this.video.currentTime = Math.max(
        0,
        Math.min(this.video.duration, this.video.currentTime + seconds)
      );
    }
  },

  // ============================================
  // Watch Time Tracking
  // ============================================

  trackWatchTime() {
    this.watchInterval = setInterval(() => {
      const duration = Math.floor((Date.now() - this.startTime) / 1000);
      if (duration > 0 && duration % 30 === 0) {
        this.pushEvent("update_watch_time", { duration });
      }
    }, 1000);
  },

  // ============================================
  // Lifecycle
  // ============================================

  destroyed() {
    this.cleanup();
    this.networkMonitor?.stop();
    this.clearHideControlsTimeout();

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
