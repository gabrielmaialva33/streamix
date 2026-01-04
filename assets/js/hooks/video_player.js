import Hls from "hls.js";
import mpegts from "mpegts.js";
import {
  ContentType,
  selectStreamingMode,
  getStreamingConfig,
} from "../lib/streaming_config";
import { NetworkMonitor } from "../lib/network_monitor";
import { PlayerUI } from "../lib/player_ui";
import { StreamLoader, getStreamType, getFileExtension, supportsHEVCNatively } from "../lib/stream_loader";
import {
  getPreferences,
  saveVolume,
  saveMuted,
  saveAudioTrack,
  saveSubtitleTrack,
  savePlaybackRate,
  savePreferAVPlayer,
} from "../lib/player_preferences";
import { playerLogger as log } from "../lib/logger";

// Lazy load AVPlayer only when needed
let AVPlayerWrapper = null;
let detectAudioIssue = null;

async function loadAVPlayer() {
  if (!AVPlayerWrapper) {
    log.debug("Lazy loading AVPlayer module...");
    const module = await import("../lib/avplayer_wrapper");
    AVPlayerWrapper = module.AVPlayerWrapper;
    detectAudioIssue = module.detectAudioIssue;
    log.debug("AVPlayer module loaded");
  }
  return { AVPlayerWrapper, detectAudioIssue };
}

// Preload WASM files when user shows intent
let wasmPreloaded = false;
function preloadAVPlayerWasm() {
  if (wasmPreloaded) return;
  wasmPreloaded = true;

  const wasmFiles = [
    '/avplayer/decode/h264-atomic.wasm',
    '/avplayer/decode/hevc-atomic.wasm',
    '/avplayer/decode/ac3-atomic.wasm',
    '/avplayer/decode/aac-atomic.wasm',
  ];

  wasmFiles.forEach(url => {
    const link = document.createElement('link');
    link.rel = 'prefetch';
    link.href = url;
    link.as = 'fetch';
    link.crossOrigin = 'anonymous';
    document.head.appendChild(link);
  });

  log.debug("WASM files prefetch initiated");
}

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
 * - Preferences persistence (volume, tracks)
 * - Keyboard shortcuts (YouTube-style)
 * - Circuit breaker for fallback loops
 */
const VideoPlayer = {
  mounted() {
    this.initializeState();
    this.loadPreferences();
    this.initUI();
    this.initPlayer();
    this.setupEventListeners();
    this.setupNetworkMonitor();
    this.setupKeyboardShortcuts();
    this.trackWatchTime();

    // Expose hook instance on element for child hooks (like ProgressBar) to access
    this.el.__videoPlayerHook = this;

    // Preload WASM files if likely to need AVPlayer (GIndex/MKV sources)
    if (this.sourceType === "gindex" || this.preferAVPlayer) {
      preloadAVPlayerWasm();
    }
  },

  initializeState() {
    // DOM elements
    this.video = this.el.querySelector("video");

    // Stream configuration
    this.streamUrl = this.el.dataset.streamUrl;
    this.proxyUrl = this.el.dataset.proxyUrl;
    this.contentType = this.el.dataset.contentType || "live";
    this.sourceType = this.el.dataset.sourceType || null;
    this.contentId = this.el.dataset.contentId;
    this.initialMode = this.el.dataset.streamingMode || null;

    // Player instances
    this.streamLoader = null;
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
    this.manualQuality = null;
    this.availableQualities = [];

    // Track state
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.selectedAudioTrack = 0;
    this.selectedSubtitleTrack = -1;

    // Retry/fallback state with circuit breaker
    this.retryCount = 0;
    this.maxRetries = 3;
    this.useProxy = true;
    this.fallbackAttempts = 0;
    this.maxFallbackAttempts = 2; // Circuit breaker limit
    this.lastFallbackTime = 0;
    this.fallbackCooldown = 30000; // 30 seconds between fallback attempts

    // Timing
    this.startTime = Date.now();
    this.lastProgressReport = 0;

    // PiP state
    this.pipActive = false;

    // Network monitor
    this.networkMonitor = null;

    // AVPlayer fallback state
    this.avPlayer = null;
    this.usingAVPlayer = false;
    this.audioCheckTimeout = null;
    this.avPlayerAttempted = false;
    this.avPlayerVolume = 1;
    this.avPlayerMuted = false;
    this.avPlayerTimeInterval = null;
    this.preferAVPlayer = false; // Manual audio compatibility mode
  },

  loadPreferences() {
    const prefs = getPreferences(this.contentId);

    // Apply volume
    this.avPlayerVolume = prefs.volume;
    this.avPlayerMuted = prefs.muted;
    if (this.video) {
      this.video.volume = prefs.volume;
      this.video.muted = prefs.muted;
    }

    // Store track preferences to apply after manifest loads
    this._preferredAudioTrack = prefs.audioTrack;
    this._preferredSubtitleTrack = prefs.subtitleTrack;

    // Playback rate
    if (this.video && prefs.playbackRate !== 1) {
      this.video.playbackRate = prefs.playbackRate;
    }

    // Manual AVPlayer preference
    this.preferAVPlayer = prefs.preferAVPlayer;
  },

  initUI() {
    this.playerUI = new PlayerUI(this.el);

    // Setup retry button
    const retryBtn = this.el.querySelector(".retry-btn");
    if (retryBtn) {
      retryBtn.addEventListener("click", () => {
        this.playerUI.hideError();
        this.retryCount = 0;
        this.fallbackAttempts = 0;
        this.initPlayer();
      });
    }
  },

  // ============================================
  // Network Monitoring
  // ============================================

  setupNetworkMonitor() {
    this.networkMonitor = new NetworkMonitor({
      onQualityChange: (newQuality, oldQuality, stats) => {
        log.debug(`Network quality changed: ${oldQuality} -> ${newQuality}`, stats);

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

    log.debug(`Switching streaming mode: ${this.streamingMode} -> ${newMode}`);
    this.streamingMode = newMode;

    if (this.streamLoader) {
      this.streamLoader.updateStreamingMode(newMode);
    }

    this.pushEvent("streaming_mode_changed", {
      mode: newMode,
      config: getStreamingConfig(newMode).name,
    });
  },

  // ============================================
  // Quality Selection
  // ============================================

  setQuality(levelIndex) {
    if (this.streamLoader) {
      this.streamLoader.setQuality(levelIndex);
    }
    this.manualQuality = levelIndex === -1 ? null : levelIndex;

    const quality = levelIndex === -1
      ? "auto"
      : this.availableQualities[levelIndex]?.label || `Level ${levelIndex}`;

    this.pushEvent("quality_changed", { quality, level: levelIndex });
  },

  updateQualityList() {
    if (!this.streamLoader) return;

    this.availableQualities = this.streamLoader.getQualityLevels();
    const currentLevel = this.streamLoader.getCurrentLevel();

    this.playerUI.updateQualityOptions(
      this.availableQualities,
      currentLevel,
      (level) => this.setQuality(level)
    );

    this.pushEvent("qualities_available", {
      qualities: [{ index: -1, label: "Automatico" }, ...this.availableQualities],
      current: currentLevel,
    });
  },

  // ============================================
  // Audio Track Selection
  // ============================================

  setAudioTrack(trackIndex) {
    if (this.streamLoader) {
      this.streamLoader.setAudioTrack(trackIndex);
    }
    this.selectedAudioTrack = trackIndex;

    // Save preference
    saveAudioTrack(trackIndex, this.contentId);

    const track = this.audioTracks[trackIndex];
    this.pushEvent("audio_track_changed", {
      track: trackIndex,
      label: track?.name || track?.lang || `Track ${trackIndex}`,
    });
  },

  updateAudioTracks() {
    const hls = this.streamLoader?.getHls();
    if (!hls) return;

    this.audioTracks = hls.audioTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Audio ${index + 1}`,
    }));

    const currentTrack = hls.audioTrack;

    this.playerUI.updateAudioOptions(
      this.audioTracks,
      currentTrack,
      (track) => this.setAudioTrack(track)
    );

    // Apply saved preference
    if (this._preferredAudioTrack !== null && this._preferredAudioTrack < this.audioTracks.length) {
      this.setAudioTrack(this._preferredAudioTrack);
    }

    this.pushEvent("audio_tracks_available", {
      tracks: this.audioTracks,
      current: currentTrack,
    });
  },

  // ============================================
  // Subtitle Track Selection
  // ============================================

  setSubtitleTrack(trackIndex) {
    if (this.streamLoader) {
      this.streamLoader.setSubtitleTrack(trackIndex);
    }
    this.selectedSubtitleTrack = trackIndex;

    // Save preference
    saveSubtitleTrack(trackIndex, this.contentId);

    const track = trackIndex >= 0 ? this.subtitleTracks[trackIndex] : null;
    this.pushEvent("subtitle_track_changed", {
      track: trackIndex,
      label: track?.name || track?.lang || (trackIndex === -1 ? "Desativado" : `Faixa ${trackIndex}`),
    });
  },

  updateSubtitleTracks() {
    const hls = this.streamLoader?.getHls();
    if (!hls) return;

    this.subtitleTracks = hls.subtitleTracks.map((track, index) => ({
      index,
      id: track.id,
      name: track.name,
      lang: track.lang,
      label: track.name || track.lang || `Legenda ${index + 1}`,
    }));

    const currentTrack = hls.subtitleTrack;

    this.playerUI.updateSubtitleOptions(
      this.subtitleTracks,
      currentTrack,
      (track) => this.setSubtitleTrack(track)
    );

    // Apply saved preference
    if (this._preferredSubtitleTrack !== null && this._preferredSubtitleTrack < this.subtitleTracks.length) {
      this.setSubtitleTrack(this._preferredSubtitleTrack);
    }

    this.pushEvent("subtitle_tracks_available", {
      tracks: [{ index: -1, label: "Desativado" }, ...this.subtitleTracks],
      current: currentTrack,
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
    // DOM Custom Events from UI Controls
    this.el.addEventListener("player:toggle-play", () => this.togglePlayPause());
    this.el.addEventListener("player:toggle-mute", () => this.toggleMute());
    this.el.addEventListener("player:toggle-fullscreen", () => this.toggleFullscreen());
    this.el.addEventListener("player:toggle-pip", () => this.togglePiP());
    this.el.addEventListener("player:set-speed", (e) => {
      const speed = parseFloat(e.detail?.speed || 1);
      this.setPlaybackRate(speed);
    });
    this.el.addEventListener("player:toggle-avplayer", () => this.toggleAVPlayerPreference());

    // Mobile Touch Support
    this.setupMobileControls();

    // Volume slider input
    const volumeSlider = this.el.querySelector("#volume-slider");
    if (volumeSlider) {
      volumeSlider.addEventListener("input", (e) => {
        const volume = parseInt(e.target.value, 10) / 100;
        this.setVolume(volume);
      });
    }

    // Video Element Events
    this.video?.addEventListener("play", () => this.playerUI.updatePlayPauseUI(false));
    this.video?.addEventListener("pause", () => this.playerUI.updatePlayPauseUI(true));
    this.video?.addEventListener("volumechange", () => this.updateVolumeUI());
    this.video?.addEventListener("timeupdate", () => this.updateTimeUI());
    this.video?.addEventListener("loadedmetadata", () => this.updateTimeUI());
    this.video?.addEventListener("ratechange", () => this.playerUI.updateSpeedUI(this.video.playbackRate));
    this.video?.addEventListener("progress", () => this.updateBufferBar());

    // Fullscreen events
    document.addEventListener("fullscreenchange", () => this.playerUI.updateFullscreenUI(!!document.fullscreenElement));
    document.addEventListener("webkitfullscreenchange", () => this.playerUI.updateFullscreenUI(!!document.fullscreenElement));

    // LiveView commands
    this.handleEvent("set_quality", ({ level }) => this.setQuality(level));
    this.handleEvent("set_audio_track", ({ track }) => this.setAudioTrack(track));
    this.handleEvent("set_subtitle_track", ({ track }) => this.setSubtitleTrack(track));
    this.handleEvent("toggle_pip", () => this.togglePiP());
    this.handleEvent("set_streaming_mode", ({ mode }) => this.switchStreamingMode(mode));
    this.handleEvent("seek", ({ time }) => this.seekTo(time));
    this.handleEvent("set_playback_rate", ({ rate }) => this.setPlaybackRate(rate));
    this.handleEvent("refresh_token", ({ url, proxyUrl }) => {
      // Handle token refresh from server
      log.debug("[VideoPlayer] Token refreshed, updating URLs");
      this.streamUrl = url;
      this.proxyUrl = proxyUrl;
      this.retryCount = 0;
      this.initPlayer();
    });

    // PiP events
    this.video?.addEventListener("enterpictureinpicture", () => {
      this.pipActive = true;
      this.pushEvent("pip_toggled", { active: true });
    });

    this.video?.addEventListener("leavepictureinpicture", () => {
      this.pipActive = false;
      this.pushEvent("pip_toggled", { active: false });
    });

    // Progress tracking for VOD
    if (this.contentType === "vod") {
      this.video?.addEventListener("timeupdate", () => this.reportProgress());
      this.video?.addEventListener("durationchange", () => {
        if (this.video.duration && isFinite(this.video.duration)) {
          this.pushEvent("duration_available", {
            duration: Math.floor(this.video.duration),
          });
        }
      });
    }

    // Buffer health monitoring
    this.video?.addEventListener("waiting", () => {
      this.pushEvent("buffering", { buffering: true });
    });

    this.video?.addEventListener("playing", () => {
      this.pushEvent("buffering", { buffering: false });
      this.playerUI.hideLoading();
      this.playerUI.hideError();
    });
  },

  // ============================================
  // UI Update Helpers
  // ============================================

  updateVolumeUI() {
    let volume, muted;
    if (this.usingAVPlayer) {
      volume = this.avPlayerVolume;
      muted = this.avPlayerMuted;
    } else {
      volume = this.video?.volume || 1;
      muted = this.video?.muted || false;
    }
    this.playerUI.updateVolumeUI(volume, muted);
  },

  updateTimeUI() {
    const currentTime = this.getCurrentTime();
    const duration = this.getDuration();
    this.playerUI.updateTimeUI(currentTime, duration);
  },

  updateBufferBar() {
    if (this.video && this.video.buffered) {
      this.playerUI.updateBufferBar(this.video.buffered, this.video.duration);
    }
  },

  setVolume(volume) {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayerVolume = volume;
      if (volume > 0 && this.avPlayerMuted) {
        this.avPlayerMuted = false;
      }
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : volume);
    } else if (this.video) {
      this.video.volume = volume;
      if (volume > 0 && this.video.muted) {
        this.video.muted = false;
      }
    }
    saveVolume(volume);
    this.updateVolumeUI();
  },

  setPlaybackRate(rate) {
    if (this.video) {
      this.video.playbackRate = rate;
      savePlaybackRate(rate);
      this.pushEvent("playback_rate_changed", { rate });
    }
  },

  reportProgress() {
    const currentTime = Math.floor(this.getCurrentTime());
    const duration = Math.floor(this.getDuration());

    if (!duration || duration <= 0) return;

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
  // URL Handling
  // ============================================

  getEffectiveUrl(streamType) {
    const isHttpUrl = this.streamUrl?.startsWith("http://");
    const isHttpsPage = window.location.protocol === "https:";

    if (isHttpUrl && isHttpsPage && this.proxyUrl) {
      log.debug("Using proxy URL for", streamType, "stream (HTTP -> HTTPS proxy required)");
      return this.toAbsoluteUrl(this.proxyUrl);
    }

    const proxyableTypes = ["ts", "xtream", "unknown"];
    if (this.useProxy && this.proxyUrl && proxyableTypes.includes(streamType)) {
      log.debug("Using proxy URL for", streamType, "stream");
      return this.toAbsoluteUrl(this.proxyUrl);
    }

    log.debug("Using direct URL for", streamType, "stream");
    return this.streamUrl;
  },

  toAbsoluteUrl(url) {
    if (!url) return url;
    if (url.startsWith("http://") || url.startsWith("https://")) {
      return url;
    }
    return new URL(url, window.location.origin).href;
  },

  // ============================================
  // Player Initialization
  // ============================================

  cleanup() {
    if (this.streamLoader) {
      this.streamLoader.destroy();
      this.streamLoader = null;
    }
    this.hls = null;
    this.mpegtsPlayer = null;

    this.stopAVPlayerTimeUpdates();
    if (this.avPlayer) {
      this.avPlayer.destroy();
      this.avPlayer = null;
    }
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }
    if (this.nativePlaybackTimeout) {
      clearTimeout(this.nativePlaybackTimeout);
      this.nativePlaybackTimeout = null;
    }

    const avContainer = this.el?.querySelector("#avplayer-container");
    if (avContainer) {
      avContainer.remove();
    }

    this.usingAVPlayer = false;
    this.avPlayerAttempted = false;

    if (this.video) {
      this.video.src = "";
      this.video.load();
    }
  },

  initPlayer() {
    if (!this.streamUrl) {
      this.playerUI.showError("URL do stream nao fornecida");
      return;
    }

    this.playerUI.showLoading();
    log.info("Initializing player with URL:", this.streamUrl);
    log.debug("Streaming mode:", this.streamingMode);
    log.debug("Content type:", this.contentType);
    log.debug("Source type:", this.sourceType);

    this.currentStreamType = getStreamType(this.streamUrl);
    log.debug("Detected stream type:", this.currentStreamType);

    this.cleanup();
    this.currentUrl = this.getEffectiveUrl(this.currentStreamType);

    // Create stream loader
    this.streamLoader = new StreamLoader({
      video: this.video,
      streamingMode: this.streamingMode,
      contentType: this.contentType,
      onManifestParsed: (data) => {
        log.info("Manifest parsed, levels:", data.levels.length);
        this.playerUI.hideLoading();
        this.playerUI.hideError();
        this.updateQualityList();
        this.updateAudioTracks();
        this.updateSubtitleTracks();

        this.video.play().catch((e) => {
          log.debug("Autoplay prevented:", e);
          this.playerUI.showPlayButton(() => this.video.play());
        });
      },
      onError: (type, data) => this.handleStreamError(type, data),
      onLevelSwitched: (level, levelData) => {
        this.pushEvent("quality_switched", {
          level,
          height: levelData?.height,
          bitrate: levelData?.bitrate,
          auto: this.manualQuality === null,
        });
      },
      onAudioTracksUpdated: () => this.updateAudioTracks(),
      onSubtitleTracksUpdated: () => this.updateSubtitleTracks(),
      onFragLoaded: (bandwidth) => this.networkMonitor?.addSample(bandwidth),
      onMediaInfo: () => {
        this.playerUI.hideLoading();
        this.playerUI.hideError();
      },
      onStatisticsInfo: (bps) => this.networkMonitor?.addSample(bps),
    });

    this.pushEvent("player_initializing", {
      stream_type: this.currentStreamType,
      streaming_mode: this.streamingMode,
      pip_supported: this.isPiPSupported(),
    });

    // Check for manual AVPlayer preference or GIndex sources
    if (this.preferAVPlayer && (this.sourceType === "gindex" || this.currentStreamType === "mkv")) {
      log.debug("Using AVPlayer due to user preference");
      this.tryAVPlayerFallback();
      return;
    }

    // GIndex uses native playback
    if (this.sourceType === "gindex") {
      log.debug("Using native playback for GIndex source");
      this.playNative();
      return;
    }

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
          this.playerUI.showError("Reproducao FLV nao suportada neste navegador");
        }
        break;
      case "mp4":
      case "mkv":
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

  handleStreamError(type, data) {
    if (type === 'hls') {
      if (data.fatal) {
        // Check for auth errors (403/401)
        if (data.response?.code === 403 || data.response?.code === 401) {
          log.warn("Auth error detected, requesting token refresh");
          this.pushEvent("request_token_refresh", {});
          return;
        }

        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            if (data.details === Hls.ErrorDetails.MANIFEST_LOAD_ERROR ||
                data.details === Hls.ErrorDetails.MANIFEST_PARSING_ERROR) {
              if (this.retryCount < this.maxRetries && mpegts.getFeatureList().mseLivePlayback) {
                this.retryCount++;
                log.warn("HLS failed, trying mpegts.js...");
                this.cleanup();
                this.playWithMpegts();
              } else {
                this.playerUI.showError("Nao foi possivel carregar - servidor indisponivel");
              }
            } else {
              log.warn("Network error, trying to recover...");
              this.streamLoader?.startLoad();
            }
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            log.warn("Media error, trying to recover...");
            this.streamLoader?.recoverMediaError();
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
              this.playerUI.showError("Erro de reproducao - formato nao suportado");
            }
        }
      }
    } else if (type === 'mpegts') {
      const { errorType, errorDetail } = data;

      if (this.useProxy && this.currentUrl !== this.streamUrl) {
        log.warn("Proxy failed, trying direct URL...");
        this.useProxy = false;
        this.currentUrl = this.streamUrl;
        this.cleanup();
        this.playWithMpegts();
        return;
      }

      if (this.retryCount < this.maxRetries) {
        this.retryCount++;
        log.warn(`Retrying with different method (${this.retryCount}/${this.maxRetries})`);
        this.cleanup();

        if (Hls.isSupported()) {
          this.playWithHls();
        } else {
          this.playNative();
        }
      } else {
        this.playerUI.showError(`Erro no stream: ${errorDetail || errorType}`);
      }
    }
  },

  playWithHls() {
    log.info("Playing with HLS.js, url:", this.currentUrl);

    if (!Hls.isSupported()) {
      if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
        this.playNative();
      } else {
        this.playerUI.showError("HLS nao suportado neste navegador");
      }
      return;
    }

    this.hls = this.streamLoader.loadHls(this.currentUrl);
  },

  playWithMpegts(type = "mpegts") {
    log.info("Playing with mpegts.js, type:", type, "url:", this.currentUrl);

    try {
      this.mpegtsPlayer = this.streamLoader.loadMpegts(this.currentUrl, type);

      this.video.play().catch((e) => {
        log.debug("Autoplay prevented:", e);
        if (e.name === "NotAllowedError") {
          this.playerUI.hideLoading();
          this.playerUI.showPlayButton(() => this.video.play());
        }
      });

      this.video.addEventListener("playing", () => {
        this.playerUI.hideLoading();
        this.playerUI.hideError();
      }, { once: true });
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
    log.info("Playing with native video element, url:", this.currentUrl);
    this.video.src = this.currentUrl;

    const playHandler = () => {
      log.debug("Native playback started");
      this.playerUI.hideLoading();
      this.playerUI.hideError();
      this.video.removeEventListener("playing", playHandler);

      if (this.nativePlaybackTimeout) {
        clearTimeout(this.nativePlaybackTimeout);
        this.nativePlaybackTimeout = null;
      }

      // Check for audio issues (GIndex/MKV with AC3/DTS)
      if (this.sourceType === "gindex" || this.currentStreamType === "mkv") {
        this.checkAudioAndFallback();
      }
    };

    const errorHandler = () => {
      if (this.usingAVPlayer || this.avPlayerAttempted) {
        log.debug("[VideoPlayer] Ignoring native video error - AVPlayer is active");
        return;
      }

      const error = this.video.error;
      let message = "Falha na reproducao";

      if (error) {
        switch (error.code) {
          case MediaError.MEDIA_ERR_ABORTED:
            message = "Reproducao cancelada";
            break;
          case MediaError.MEDIA_ERR_NETWORK:
            message = "Erro de rede - verifique sua conexao";
            break;
          case MediaError.MEDIA_ERR_DECODE:
          case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED:
            if ((this.sourceType === "gindex" || this.currentStreamType === "mkv") && !this.avPlayerAttempted) {
              log.debug("[VideoPlayer] Format not supported, trying AVPlayer fallback");
              this.tryAVPlayerFallback();
              return;
            }
            message = "Formato nao suportado pelo navegador";
            break;
        }
      }

      this.playerUI.showError(message);
      this.video.removeEventListener("error", errorHandler);
    };

    this._nativeErrorHandler = errorHandler;

    this.video.addEventListener("playing", playHandler);
    this.video.addEventListener("error", errorHandler);
    this.video.addEventListener("loadedmetadata", () => this.playerUI.hideLoading(), { once: true });

    this.video.play().catch((e) => {
      log.debug("Native autoplay prevented:", e);
      this.playerUI.hideLoading();
      if (e.name === "NotAllowedError") {
        this.playerUI.showPlayButton(() => this.video.play());
      } else if (e.name === "NotSupportedError" && (this.sourceType === "gindex" || this.currentStreamType === "mkv")) {
        log.debug("[VideoPlayer] Native play failed, AVPlayer fallback will be attempted");
      } else {
        this.playerUI.showError("Falha ao iniciar reproducao: " + e.message);
      }
    });
  },

  // ============================================
  // Audio Detection and AVPlayer Fallback
  // ============================================

  async checkAudioAndFallback() {
    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
    }

    this.audioCheckTimeout = setTimeout(async () => {
      try {
        const { detectAudioIssue } = await loadAVPlayer();
        const hasAudioIssue = await detectAudioIssue(this.video);

        if (hasAudioIssue) {
          log.debug("[VideoPlayer] Audio issue detected, auto-switching to AVPlayer");
          this.tryAVPlayerFallback();
        } else {
          log.debug("[VideoPlayer] Audio working correctly");
        }
      } catch (e) {
        console.warn("[VideoPlayer] Could not check audio:", e);
      }
    }, 2000);
  },

  /**
   * Check circuit breaker before attempting fallback
   */
  canAttemptFallback() {
    const now = Date.now();

    // Check if we've exceeded max attempts
    if (this.fallbackAttempts >= this.maxFallbackAttempts) {
      // Allow retry after cooldown
      if (now - this.lastFallbackTime < this.fallbackCooldown) {
        log.debug("[VideoPlayer] Circuit breaker: too many fallback attempts, cooling down");
        return false;
      }
      // Reset after cooldown
      this.fallbackAttempts = 0;
    }

    return true;
  },

  async tryAVPlayerFallback() {
    // Circuit breaker check
    if (!this.canAttemptFallback()) {
      log.debug("[VideoPlayer] Circuit breaker prevented fallback attempt");
      this.playerUI.showError("Formato de audio nao suportado. Tente novamente mais tarde.");
      return;
    }

    if (this.avPlayerAttempted || this.usingAVPlayer) {
      log.debug("[VideoPlayer] AVPlayer fallback already attempted, skipping");
      return;
    }

    this.avPlayerAttempted = true;
    this.fallbackAttempts++;
    this.lastFallbackTime = Date.now();

    if (this.audioCheckTimeout) {
      clearTimeout(this.audioCheckTimeout);
      this.audioCheckTimeout = null;
    }

    log.debug("[VideoPlayer] Attempting AVPlayer fallback (seamless)");
    this.playerUI.hideError();

    const currentTime = this.video.currentTime || 0;
    const wasPlaying = !this.video.paused;

    this.video.pause();

    if (this._nativeErrorHandler) {
      this.video.removeEventListener("error", this._nativeErrorHandler);
    }

    try {
      // Lazy load AVPlayer
      const { AVPlayerWrapper } = await loadAVPlayer();

      const avContainer = document.createElement("div");
      avContainer.id = "avplayer-container";
      avContainer.className = "absolute inset-0 z-0";
      this.el.appendChild(avContainer);

      this.video.classList.add("hidden");
      this.video.src = "";

      this.avPlayer = new AVPlayerWrapper({
        container: avContainer,
        onReady: () => log.debug("[VideoPlayer] AVPlayer ready"),
        onPlay: () => {
          log.debug("[VideoPlayer] AVPlayer playing with audio support");
          this.playerUI.hideLoading();
          this.playerUI.updatePlayPauseUI(false);
          this.startAVPlayerTimeUpdates();
        },
        onPause: () => {
          log.debug("[VideoPlayer] AVPlayer paused");
          this.playerUI.updatePlayPauseUI(true);
        },
        onError: (error) => {
          log.error("[VideoPlayer] AVPlayer error:", error);
          this.revertToNativePlayer();
        },
        onTimeUpdate: () => this.updateTimeUI(),
        onEnded: () => {
          log.debug("[VideoPlayer] AVPlayer ended");
          this.playerUI.updatePlayPauseUI(true);
          this.stopAVPlayerTimeUpdates();
        },
      });

      const avPlayerUrl = this.proxyUrl
        ? this.toAbsoluteUrl(this.proxyUrl)
        : this.streamUrl;

      const ext = getFileExtension(this.streamUrl, this.sourceType, this.currentStreamType);
      log.debug("[VideoPlayer] AVPlayer loading via:", avPlayerUrl, "ext:", ext);

      await this.avPlayer.load(avPlayerUrl, { ext });

      if (currentTime > 0) {
        await this.avPlayer.seek(currentTime);
      }

      // Apply saved volume
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : this.avPlayerVolume);

      log.debug("[VideoPlayer] Calling AVPlayer play(), wasPlaying:", wasPlaying);
      await this.avPlayer.play();
      log.debug("[VideoPlayer] AVPlayer play() completed");

      this.usingAVPlayer = true;
      log.debug("[VideoPlayer] Seamless AVPlayer switch complete");

    } catch (error) {
      log.error("[VideoPlayer] AVPlayer fallback failed:", error);
      this.revertToNativePlayer();
    }
  },

  revertToNativePlayer() {
    log.debug("[VideoPlayer] Reverting to native player");

    this.stopAVPlayerTimeUpdates();

    if (this.avPlayer) {
      this.avPlayer.destroy();
      this.avPlayer = null;
    }

    const avContainer = this.el.querySelector("#avplayer-container");
    if (avContainer) {
      avContainer.remove();
    }

    this.video.classList.remove("hidden");
    this.usingAVPlayer = false;
  },

  toggleAVPlayerPreference() {
    this.preferAVPlayer = !this.preferAVPlayer;
    savePreferAVPlayer(this.preferAVPlayer);

    log.debug("[VideoPlayer] AVPlayer preference toggled:", this.preferAVPlayer);

    // Restart player with new preference
    if (this.sourceType === "gindex" || this.currentStreamType === "mkv") {
      this.avPlayerAttempted = false;
      this.fallbackAttempts = 0;
      this.initPlayer();
    }

    this.pushEvent("avplayer_preference_changed", { enabled: this.preferAVPlayer });
  },

  startAVPlayerTimeUpdates() {
    this.stopAVPlayerTimeUpdates();
    this._avPlayerAnimating = true;
    this._lastTimeUpdate = 0;

    const updateLoop = (timestamp) => {
      if (!this._avPlayerAnimating) return;

      // Throttle updates to ~4fps (250ms) to match previous behavior
      // but using rAF for better CPU efficiency when tab is inactive
      if (timestamp - this._lastTimeUpdate >= 250) {
        this._lastTimeUpdate = timestamp;
        if (this.usingAVPlayer && this.avPlayer) {
          this.updateTimeUI();
          if (this.contentType === "vod") {
            this.reportProgress();
          }
        }
      }

      this.avPlayerTimeInterval = requestAnimationFrame(updateLoop);
    };

    this.avPlayerTimeInterval = requestAnimationFrame(updateLoop);
  },

  stopAVPlayerTimeUpdates() {
    this._avPlayerAnimating = false;
    if (this.avPlayerTimeInterval) {
      cancelAnimationFrame(this.avPlayerTimeInterval);
      this.avPlayerTimeInterval = null;
    }
  },

  // ============================================
  // Mobile Touch Controls
  // ============================================

  setupMobileControls() {
    const controls = this.el.querySelector("#player-controls");
    if (!controls) return;

    this.lastTapTime = 0;
    const isTouchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;

    if (isTouchDevice) {
      this.video.addEventListener("click", (e) => {
        e.preventDefault();
        const now = Date.now();
        const timeSinceLastTap = now - this.lastTapTime;

        if (timeSinceLastTap < 300) {
          this.toggleFullscreen();
        } else {
          this.playerUI.toggleControlsVisibility();
        }

        this.lastTapTime = now;
      });

      this.playerUI.showControls();
      this.playerUI.scheduleHideControls();

      controls.addEventListener("touchstart", () => {
        this.playerUI.clearHideControlsTimeout();
      });

      controls.addEventListener("touchend", () => {
        this.playerUI.scheduleHideControls();
      });
    }

    this.el.addEventListener("mousemove", () => {
      if (!isTouchDevice) {
        this.playerUI.showControls();
        this.playerUI.scheduleHideControls();
      }
    });

    this.video.addEventListener("play", () => {
      this.playerUI.scheduleHideControls();
    });

    this.video.addEventListener("pause", () => {
      this.playerUI.showControls();
      this.playerUI.clearHideControlsTimeout();
    });
  },

  // ============================================
  // Keyboard Shortcuts (YouTube-style)
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
        case "k":
        case "K":
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
        case "j":
        case "J":
          if (this.contentType === "vod") {
            e.preventDefault();
            this.seek(-10);
          }
          break;
        case "ArrowRight":
        case "l":
        case "L":
          if (this.contentType === "vod") {
            e.preventDefault();
            this.seek(10);
          }
          break;
        // Number keys 0-9 for percentage seek
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
            const duration = this.getDuration();
            if (duration > 0) {
              this.seekTo(duration * percent);
            }
          }
          break;
        case "<":
          // Decrease playback speed
          if (this.video) {
            const newRate = Math.max(0.25, this.video.playbackRate - 0.25);
            this.setPlaybackRate(newRate);
          }
          break;
        case ">":
          // Increase playback speed
          if (this.video) {
            const newRate = Math.min(2, this.video.playbackRate + 0.25);
            this.setPlaybackRate(newRate);
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

  async togglePlayPause() {
    if (this.usingAVPlayer && this.avPlayer) {
      const isPlaying = this.avPlayer.isPlaying();
      log.debug("[VideoPlayer] togglePlayPause: AVPlayer isPlaying =", isPlaying);
      if (isPlaying) {
        await this.avPlayer.pause();
      } else {
        try {
          await this.avPlayer.play();
        } catch (err) {
          log.error("[VideoPlayer] AVPlayer play() failed:", err);
        }
      }
    } else {
      if (this.video.paused) {
        this.video.play();
      } else {
        this.video.pause();
      }
    }
  },

  toggleMute() {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayerMuted = !this.avPlayerMuted;
      this.avPlayer.setVolume(this.avPlayerMuted ? 0 : this.avPlayerVolume || 1);
      saveMuted(this.avPlayerMuted);
    } else if (this.video) {
      this.video.muted = !this.video.muted;
      saveMuted(this.video.muted);
    }
    this.updateVolumeUI();
    this.pushEvent("mute_toggled", { muted: this.usingAVPlayer ? this.avPlayerMuted : this.video?.muted });
  },

  adjustVolume(delta) {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayerVolume = Math.max(0, Math.min(1, (this.avPlayerVolume || 1) + delta));
      if (!this.avPlayerMuted) {
        this.avPlayer.setVolume(this.avPlayerVolume);
      }
      saveVolume(this.avPlayerVolume);
    } else if (this.video) {
      this.video.volume = Math.max(0, Math.min(1, this.video.volume + delta));
      saveVolume(this.video.volume);
    }
    this.updateVolumeUI();
    this.pushEvent("volume_changed", { volume: Math.round((this.usingAVPlayer ? this.avPlayerVolume : this.video?.volume || 1) * 100) });
  },

  seek(seconds) {
    if (this.usingAVPlayer && this.avPlayer) {
      const currentTime = this.avPlayer.getCurrentTime();
      const duration = this.avPlayer.getDuration();
      if (duration > 0) {
        const newTime = Math.max(0, Math.min(duration, currentTime + seconds));
        this.avPlayer.seek(newTime);
      }
    } else if (this.video?.duration) {
      this.video.currentTime = Math.max(
        0,
        Math.min(this.video.duration, this.video.currentTime + seconds)
      );
    }
  },

  seekTo(time) {
    if (this.usingAVPlayer && this.avPlayer) {
      this.avPlayer.seek(time);
    } else if (this.video) {
      this.video.currentTime = time;
    }
  },

  getCurrentTime() {
    if (this.usingAVPlayer && this.avPlayer) {
      return this.avPlayer.getCurrentTime();
    }
    return this.video?.currentTime || 0;
  },

  getDuration() {
    if (this.usingAVPlayer && this.avPlayer) {
      return this.avPlayer.getDuration();
    }
    return this.video?.duration || 0;
  },

  isPaused() {
    if (this.usingAVPlayer && this.avPlayer) {
      return !this.avPlayer.isPlaying();
    }
    return this.video?.paused ?? true;
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
    this.playerUI?.clearHideControlsTimeout();
    this.playerUI?.destroy();
    this.stopAVPlayerTimeUpdates();

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

    if (this.el) {
      this.el.__videoPlayerHook = null;
    }
  },
};

export default VideoPlayer;
