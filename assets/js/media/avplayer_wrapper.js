export { detectAudioIssue } from "./audio_diagnostics.js";

import {
  AVCodecID,
  configureLibmediaLogging,
  configureWebpackPublicPath,
  getAVPlayerAccelerationConfig,
  getWasmUrl,
  loadScript,
} from "./avplayer_runtime.js";
import { avPlayerTracks } from "./avplayer_tracks.js";

export {
  getAVPlayerAccelerationConfig,
  preloadAVPlayerRuntime,
  preloadCommonWasm,
} from "./avplayer_runtime.js";

/**
 * AVPlayer Wrapper for libmedia
 *
 * Provides software decoding for codecs not supported by browsers,
 * including AC3, DTS, EAC3 (Dolby Digital).
 */

import { avplayerLogger as log } from "../core/logger.js";
import {
  awaitPlaybackOperation,
  createSynchronousErrorNotifier,
  stopThenDestroyPlaybackEngine,
} from "../player/playback_engine_lifecycle.js";
import { initialAVPlayerPlayOptions } from "../player/subtitle_policy.js";
import { getAvPlayerScriptUrls } from "./config.js";

// AVMediaType constants from libmedia
const _AVMediaType = {
  AVMEDIA_TYPE_VIDEO: 0,
  AVMEDIA_TYPE_AUDIO: 1,
  AVMEDIA_TYPE_DATA: 2,
  AVMEDIA_TYPE_SUBTITLE: 3,
  AVMEDIA_TYPE_ATTACHMENT: 4,
};

/**
 * AVPlayer wrapper class
 */
export class AVPlayerDestroyedError extends Error {
  constructor() {
    super("Player has been destroyed");
    this.name = "AVPlayerDestroyedError";
  }
}

export const isAVPlayerDestroyedError = (error) =>
  error instanceof AVPlayerDestroyedError || error?.name === "AVPlayerDestroyedError";

export class AVPlayerWrapper {
  constructor(options = {}) {
    this.container = options.container;
    this.onError = options.onError || (() => {});
    this._notifyError = createSynchronousErrorNotifier(this.onError);
    this.onReady = options.onReady || (() => {});
    this.onPlay = options.onPlay || (() => {});
    this.onPause = options.onPause || (() => {});
    this.onTimeUpdate = options.onTimeUpdate || (() => {});
    this.onEnded = options.onEnded || (() => {});

    this.player = null;
    this.isReady = false;
    this.currentUrl = null;
    this._destroyed = false;
    this._initPromise = null;
    this._instanceCounted = false;
    this._runtime = options.windowRef || globalThis.window;
    this._navigator = options.navigatorRef || globalThis.navigator || {};
    this._dependencies = {
      configureRuntime:
        options.configureRuntime ||
        (() => {
          configureWebpackPublicPath();
          configureLibmediaLogging();
        }),
      getAccelerationConfig: options.getAccelerationConfig || getAVPlayerAccelerationConfig,
      getScriptUrls: options.getScriptUrls || getAvPlayerScriptUrls,
      loadScript: options.loadScript || loadScript,
      createPlayer: options.createPlayer || ((config) => new this._runtime.AVPlayer(config)),
    };

    // Internal state for tracking playback
    this._playing = false;
    this._currentTimeMs = 0;
    this._durationMs = 0;
    this._volume = 1;
    // Whether the viewer picked an embedded subtitle; until then the renderer
    // play() starts stays hidden.
    this._subtitleChosen = false;
  }

  /**
   * Initialize the AVPlayer with all required dependencies
   */
  init() {
    if (this.player || this._destroyed) return Promise.resolve();
    if (this._initPromise) return this._initPromise;

    const initialization = this._initialize();
    const tracked = initialization.finally(() => {
      if (this._initPromise === tracked) this._initPromise = null;
    });
    this._initPromise = tracked;
    return tracked;
  }

  _throwIfDestroyed() {
    if (this._destroyed) throw new AVPlayerDestroyedError();
  }

  async _initialize() {
    if (this.player || this._destroyed) return;

    try {
      log.debug("Initializing...");

      // Step 1: Configure webpack public path for dynamic chunk loading
      this._dependencies.configureRuntime();

      // Step 2: Get script URLs from config
      const scriptUrls = this._dependencies.getScriptUrls();

      // Step 3: Load cheap-polyfill.js FIRST
      await this._dependencies.loadScript(scriptUrls.polyfill, "cheap-polyfill");
      this._throwIfDestroyed();
      log.debug("Loaded cheap-polyfill.js");

      // Step 4: Configure polyfill URL for BigInt fallback
      if (typeof BigInt === "undefined" || BigInt === Number) {
        this._runtime.CHEAP_POLYFILL_URL = scriptUrls.polyfill;
      }

      // Step 5: Load AVPlayer main script
      await this._dependencies.loadScript(scriptUrls.player, "avplayer-script");
      this._throwIfDestroyed();
      log.debug("Loaded avplayer.js");

      if (!this._runtime?.AVPlayer) {
        throw new Error("AVPlayer not found after loading script");
      }

      // Step 5: Initialize AudioContext (required for Web Audio API playback)
      if (!this._runtime.AVPlayer.audioContext) {
        const AudioContextClass = this._runtime.AudioContext || this._runtime.webkitAudioContext;
        this._runtime.AVPlayer.audioContext = new AudioContextClass();
        // Create a dummy source to unlock audio on mobile
        this._runtime.AVPlayer.audioContext.createBufferSource();
        log.debug("AudioContext initialized");
      }

      const accelerationConfig = this._dependencies.getAccelerationConfig();
      log.debug("Acceleration config:", accelerationConfig);

      // Step 6: Create the player instance
      // Audio/Video sync strategy:
      // - Prefer browser-native WebCodecs/hardware when the full decode pipeline exists
      // - Fall back to WASM decoders for browsers/codecs that still need compatibility
      // - Minimize AudioWorklet buffer to reduce audio latency
      // - Enable jitter buffer for smoother sync adjustments
      // Audio worklet buffer: 10 is the libmedia default. We previously
      // forced it down to 4 for "low latency", but on low-end Android
      // Chrome and older iPhones a buffer that small underruns and the
      // audio crackles or drops out. Detect mobile and back off to a
      // safer value there.
      const isLowEndMobile =
        /Android|iPhone|iPad/i.test(this._navigator.userAgent || "") &&
        (this._navigator.hardwareConcurrency || 4) <= 4;
      const audioWorkletBufferLength = isLowEndMobile ? 10 : 6;

      // Jitter buffer: previously hard-pinned to 0.2-1s for "tight sync".
      // That works on a clean desktop network but starves on flaky
      // mobile, especially when the proxy chain is slow. Use a relaxed
      // default and only tighten on capable hardware.
      const jitterBufferMin = isLowEndMobile ? 0.5 : 0.3;
      const jitterBufferMax = isLowEndMobile ? 3 : 1.5;

      this._throwIfDestroyed();
      const player = this._dependencies.createPlayer({
        container: this.container,
        getWasm: (type, codecId) => {
          const url = getWasmUrl(type, codecId);
          log.debug(`getWasm: type=${type}, codecId=${codecId}`);
          return url;
        },
        enableHardware: accelerationConfig.enableHardware,
        enableWebCodecs: accelerationConfig.enableWebCodecs,
        enableAudioWorklet: true,
        audioWorkletBufferLength,
        enableJitterBuffer: true,
        jitterBufferMin,
        jitterBufferMax,
        preLoadTime: 1,
        // NOTE: `subtitle: true` does NOT belong here. It's a `play()`
        // option (`AVPlayerPlayOptions`), not a constructor option, and
        // libmedia silently ignored it. We pass it via `play()` below.
        // `loop: false` is also dropped — it's the libmedia default.
      });
      this._throwIfDestroyed();
      this.player = player;

      // Set up event listeners
      this.setupEventListeners();

      // Track live AVPlayer instances so we don't close the shared
      // AudioContext while another player still needs it (probe +
      // main, watch-party rejoin races).
      this._runtime._avplayerInstanceCount = (this._runtime._avplayerInstanceCount || 0) + 1;
      this._instanceCounted = true;

      this.isReady = true;
      this.onReady();

      log.debug("Initialized successfully");
    } catch (error) {
      if (isAVPlayerDestroyedError(error) || this._destroyed) return;
      log.error("Failed to initialize:", error);
      this._notifyError(error);
      throw error;
    }
  }

  /**
   * Set up event listeners for the player
   */
  setupEventListeners() {
    if (!this.player) return;

    this.player.on("playing", () => {
      log.debug("Playing");
      this._playing = true;
      this.onPlay();
    });

    this.player.on("pause", () => {
      log.debug("Paused");
      this._playing = false;
      this.onPause();
    });

    this.player.on("ended", () => {
      log.debug("Ended");
      this._playing = false;
      this.onEnded();
    });

    this.player.on("error", (error) => {
      log.error("Error event:", error);
      this._notifyError(error);
    });

    // Add more event listeners for debugging
    this.player.on("loadstart", () => {
      log.debug("Event: loadstart");
    });

    this.player.on("progress", (progress) => {
      log.debug("Event: progress", progress);
    });

    this.player.on("canplay", () => {
      log.debug("Event: canplay");
    });

    this.player.on("waiting", () => {
      log.debug("Event: waiting");
    });

    this.player.on("stalled", () => {
      log.debug("Event: stalled");
    });

    this.player.on("time", (time) => {
      // time is in milliseconds
      this._currentTimeMs = typeof time === "bigint" ? Number(time) : time;
      this.onTimeUpdate(this._currentTimeMs / 1000);
    });

    this.player.on("loaded", () => {
      log.debug("Loaded");
      // Try to get duration from formatContext streams
      this._cacheDuration();
    });

    this.player.on("seeking", () => {
      log.debug("Seeking");
    });

    this.player.on("seeked", () => {
      log.debug("Seeked");
    });
  }

  /**
   * Cache the duration from the player's format context. Each stream
   * exposes its own `timeBase: { num, den }` (or `{numerator, denominator}`
   * across libmedia minor bumps). Duration is in stream-time units, so
   * `duration_ms = duration * (num / den) * 1000`. The previous version
   * tried to *guess* the timescale by trying 90000, 48000, 44100,
   * 1000000 in turn — which worked by luck on most files but produced
   * wrong durations on anything with an unusual timeBase.
   */
  _cacheDuration() {
    try {
      const streams = this.player?.formatContext?.streams;
      if (!streams) return;

      const MAX_DURATION_MS = 12 * 60 * 60 * 1000;

      for (const stream of streams) {
        if (!stream?.duration) continue;

        const durationValue =
          typeof stream.duration === "bigint" ? Number(stream.duration) : stream.duration;
        if (!(durationValue > 0)) continue;

        const tb = stream.timeBase || stream.time_base;
        const num = tb?.num ?? tb?.numerator;
        const den = tb?.den ?? tb?.denominator;

        let detectedMs = 0;
        if (num > 0 && den > 0) {
          detectedMs = (durationValue * num * 1000) / den;
        } else {
          // Fallback when libmedia hasn't populated timeBase yet:
          // assume the value is already in microseconds (FFmpeg's
          // canonical AV_TIME_BASE = 1_000_000).
          detectedMs = durationValue / 1000;
        }

        if (detectedMs > 0 && detectedMs < MAX_DURATION_MS) {
          this._durationMs = detectedMs;
          log.debug("Cached duration:", this._durationMs, "ms");
          return;
        }
      }
    } catch (e) {
      log.warn("Could not cache duration:", e);
    }
  }

  /**
   * Load a video URL
   * @param {string} url - The video URL to load
   * @param {object} options - Load options
   * @param {string} options.ext - File extension (e.g., 'mkv', 'mp4') to force format detection
   */
  async load(url, options = {}) {
    if (this._destroyed) {
      throw new AVPlayerDestroyedError();
    }

    if (!this.player) {
      await this.init();
    }

    this._throwIfDestroyed();
    const player = this.player;
    if (!player) throw new Error("Player failed to initialize");

    this.currentUrl = url;
    this._subtitleChosen = false;
    log.debug("Loading stream");
    log.debug("Load options:", options);
    log.debug("Container:", this.container);
    log.debug("Player instance:", this.player);

    try {
      log.debug("Calling player.load()...");

      const loadTimeoutMs = options.loadTimeoutMs || 30000;

      // Build load options for AVPlayer.
      //   ext     – forces format detection for URLs without extensions
      //             (`/api/stream/proxy?token=...`).
      //   isLive  – tells libmedia to use the live A/V clock + dropping
      //             strategy instead of the VOD jitter buffer. Without
      //             this, live TS streams treated as VOD will drift and
      //             stutter on long sessions.
      const loadOptions = {};
      if (options.ext) {
        loadOptions.ext = options.ext;
        log.debug("Forcing format detection with ext:", options.ext);
      }
      if (options.isLive) {
        loadOptions.isLive = true;
      }
      if (options.maxProbeDuration) {
        loadOptions.maxProbeDuration = options.maxProbeDuration;
      }
      // Configure the actual IO task, including worker IO. A window.fetch patch
      // cannot reach workers and multiplies retries when IO also retries. This
      // per-stream policy works on any origin: at most four attempts, 200ms
      // between failures (libmedia expresses retryInterval in seconds).
      loadOptions.ioLoaderOptions = {
        ...options.ioLoaderOptions,
        retryCount: 3,
        retryInterval: 0.2,
      };
      this._isLive = !!options.isLive;

      const loadResult = player.load(url, loadOptions);
      log.debug("load() returned:", loadResult);
      await awaitPlaybackOperation(loadResult, {
        timeoutMs: loadTimeoutMs,
        timeoutMessage: `Load timeout after ${Math.round(loadTimeoutMs / 1000)} seconds`,
      });

      if (this._destroyed || this.player !== player) throw new AVPlayerDestroyedError();

      log.debug("Load complete");
    } catch (error) {
      if (isAVPlayerDestroyedError(error) || this._destroyed) throw error;
      log.error("Load error:", error);
      log.error("Error stack:", error?.stack);
      this._notifyError(error);
      throw error;
    }
  }

  // Matroska tracks that omit their language are English by specification
  // (muxers drop the element when it is "eng"); libmedia leaves it empty.
  _defaultTrackLanguage() {
    return avPlayerTracks._defaultTrackLanguage.call(this);
  }

  // Stream list from AVPlayer's public API, empty before load or on versions
  // without it.
  _streams() {
    try {
      return this.player?.getStreams?.() || [];
    } catch (_error) {
      return [];
    }
  }

  /**
   * Start playback
   */
  async play() {
    if (!this.player) {
      throw new Error("Player not initialized");
    }

    log.debug("play() called, _playing:", this._playing);
    log.debug("AudioContext state:", window.AVPlayer?.audioContext?.state);

    try {
      // Resume AudioContext if suspended (required after user interaction)
      if (window.AVPlayer?.audioContext?.state === "suspended") {
        log.debug("Resuming AudioContext...");
        await window.AVPlayer.audioContext.resume();
        log.debug("AudioContext resumed, new state:", window.AVPlayer?.audioContext?.state);
      }
      log.debug("Calling player.play()...");
      // See initialAVPlayerPlayOptions: the subtitle renderer has to start
      // here for any embedded subtitle to work later, but it starts showing
      // the file's default track, so it is hidden until the viewer picks one.
      const options = initialAVPlayerPlayOptions(this._streams());
      const playResult = this.player.play(options);
      log.debug("player.play() returned:", playResult);
      if (playResult && typeof playResult.then === "function") {
        await playResult;
      }
      if (options.subtitle && !this._subtitleChosen) {
        this.player?.setSubtitleEnable?.(false);
      }
      // Manually set _playing in case event doesn't fire
      this._playing = true;
      log.debug("play() completed successfully, _playing:", this._playing);
      // Manually call onPlay since event might not fire on resume
      this.onPlay();
    } catch (error) {
      log.error("Play error:", error);
      this._notifyError(error);
      throw error;
    }
  }

  /**
   * Pause playback
   */
  async pause() {
    if (this.player) {
      log.debug("pause() called, _playing:", this._playing);
      const pauseResult = this.player.pause();
      log.debug("player.pause() returned:", pauseResult);
      if (pauseResult && typeof pauseResult.then === "function") {
        await pauseResult;
      }
      // Manually set _playing in case event doesn't fire
      this._playing = false;
      log.debug("pause() completed, _playing:", this._playing);
      // Manually call onPause since event might not fire
      this.onPause();
    }
  }

  /**
   * Stop playback
   */
  async stop() {
    if (this.player) {
      await this.player.stop();
    }
  }

  /**
   * Seek to a specific time in seconds
   */
  async seek(time) {
    if (!this.player) return;

    this._pendingSeekTime = Math.max(0, Number(time) || 0);

    if (this._seekPromise) {
      return this._seekPromise;
    }

    this._seekPromise = (async () => {
      while (this._pendingSeekTime != null && !this._destroyed) {
        const targetTime = this._pendingSeekTime;
        this._pendingSeekTime = null;
        await this.performSeek(targetTime);
      }
    })().finally(() => {
      this._seekPromise = null;
      this._pendingSeekTime = null;
    });

    return this._seekPromise;
  }

  async performSeek(time) {
    // AVPlayer seek uses milliseconds as int64
    const timeMs = Math.floor(time * 1000);
    log.debug("Seeking to", time, "seconds (", timeMs, "ms)");
    try {
      await this.player.seek(BigInt(timeMs));
    } catch (e) {
      // Fallback without BigInt if needed
      log.warn("Seek with BigInt failed, trying without:", e);
      await this.player.seek(timeMs);
    }
  }

  /**
   * Set volume (0-1)
   */
  setVolume(volume) {
    this._volume = volume;
    if (this.player) {
      this.player.setVolume(volume);
    }
  }

  /**
   * Get current playback time in seconds
   */
  getCurrentTime() {
    // Use cached time from 'time' event (more reliable)
    if (this._currentTimeMs > 0) {
      return this._currentTimeMs / 1000;
    }

    // Fallback: try to get from player.currentTime property
    if (this.player) {
      try {
        const time = this.player.currentTime;
        if (time !== undefined && time !== null) {
          const timeValue = typeof time === "bigint" ? Number(time) : time;
          // currentTime is in milliseconds
          return timeValue / 1000;
        }
      } catch (_e) {
        // Ignore errors
      }
    }

    return 0;
  }

  /**
   * Get total duration in seconds
   */
  getDuration() {
    // Use cached duration (most reliable)
    if (this._durationMs > 0) {
      return this._durationMs / 1000;
    }

    // Fallback: try to get from player.duration property
    if (this.player) {
      try {
        const duration = this.player.duration;
        if (duration !== undefined && duration !== null) {
          const durationValue = typeof duration === "bigint" ? Number(duration) : duration;
          // duration is in milliseconds
          return durationValue / 1000;
        }
      } catch (_e) {
        // Ignore errors
      }
    }

    return 0;
  }

  /**
   * Check if currently playing
   */
  isPlaying() {
    return this._playing;
  }

  /**
   * Get list of audio tracks from the media
   * @returns {Array} Array of audio track objects with id, index, label, language
   */
  async getAudioTracks() {
    return avPlayerTracks.getAudioTracks.call(this);
  }

  /**
   * Get list of subtitle tracks from the media
   * @returns {Array} Array of subtitle track objects with id, index, label, language
   */
  async getSubtitleTracks() {
    return avPlayerTracks.getSubtitleTracks.call(this);
  }

  /**
   * Add an external subtitle track to the current media.
   * @param {{source: string|File, lang?: string, title?: string}} externalSubtitle
   * @returns {Promise<number>} The AVPlayer stream id
   */
  async loadExternalSubtitle(externalSubtitle) {
    if (!this.player || typeof this.player.loadExternalSubtitle !== "function") {
      throw new Error("AVPlayer external subtitles are unavailable");
    }

    return await this.player.loadExternalSubtitle(externalSubtitle);
  }

  /**
   * Select an audio track by ID
   * @param {number} trackId - The track ID to select
   */
  async selectAudioTrack(trackId) {
    if (!this.player) return false;

    try {
      // Save current position before switching
      const currentTime = this.getCurrentTime();
      const wasPlaying = this._playing;

      log.debug(`Selecting audio track: ${trackId}, currentTime: ${currentTime}`);

      // Switch the audio track
      await this.player.selectAudio(trackId);
      log.debug(`Audio track ${trackId} selected`);

      // Force resync by seeking to current position
      // This ensures audio is at the same position as video
      if (currentTime > 0) {
        log.debug(`Resyncing audio to position: ${currentTime}`);
        await this.seek(currentTime);

        // Resume playback if it was playing
        if (wasPlaying) {
          await this.play();
        }
      }

      log.debug(`Audio track switch complete with resync`);
      return trackId;
    } catch (e) {
      log.error("Error selecting audio track:", e);
      throw e;
    }
  }

  /**
   * Select a subtitle track by ID (-1 to disable)
   * @param {number} trackId - The track ID to select, or -1 to disable subtitles
   */
  async selectSubtitleTrack(trackId) {
    if (!this.player) return false;

    try {
      log.debug(`Selecting subtitle track: ${trackId}`);
      this._subtitleChosen = trackId !== -1;
      if (trackId === -1) {
        if (typeof this.player.setSubtitleEnable === "function") {
          this.player.setSubtitleEnable(false);
        } else if (typeof this.player.hideSubtitle === "function") {
          await this.player.hideSubtitle();
        } else {
          await this.player.selectSubtitle(-1);
        }
      } else {
        // libmedia refuses to "select" the stream its renderer already holds
        // (the default it starts with); that one only needs enabling.
        if (this.player.getSelectedSubtitleStreamId?.() !== trackId) {
          await this.player.selectSubtitle(trackId);
        }
        this.player.setSubtitleEnable?.(true);
      }
      log.debug(`Subtitle track ${trackId} selected`);
      return trackId;
    } catch (e) {
      log.error("Error selecting subtitle track:", e);
      throw e;
    }
  }

  /**
   * Shift subtitle rendering without reloading the media.
   * Positive values delay subtitles; negative values advance them.
   * @param {number} delayMs
   */
  setSubtitleDelay(delayMs) {
    const delay = Number(delayMs);
    if (
      !this.player ||
      typeof this.player.setSubtitleDelay !== "function" ||
      !Number.isFinite(delay)
    ) {
      return false;
    }

    const normalized = Math.trunc(delay);
    this.player.setSubtitleDelay(normalized);
    return normalized;
  }

  /**
   * Get human-readable codec name from codec ID
   * @private
   */
  _getCodecName(codecId) {
    const names = {
      [AVCodecID.AV_CODEC_ID_AAC]: "AAC",
      [AVCodecID.AV_CODEC_ID_MP3]: "MP3",
      [AVCodecID.AV_CODEC_ID_AC3]: "AC3",
      [AVCodecID.AV_CODEC_ID_EAC3]: "E-AC3",
      [AVCodecID.AV_CODEC_ID_DTS]: "DTS",
      [AVCodecID.AV_CODEC_ID_FLAC]: "FLAC",
      [AVCodecID.AV_CODEC_ID_OPUS]: "Opus",
      [AVCodecID.AV_CODEC_ID_VORBIS]: "Vorbis",
    };
    return names[codecId] || `Codec ${codecId}`;
  }

  /**
   * Destroy the player and cleanup
   */
  async destroy() {
    if (this._destroyed) return;

    this._destroyed = true;
    this._pendingSeekTime = null;
    this._playing = false;

    if (this.player) {
      const player = this.player;
      this.player = null;

      await stopThenDestroyPlaybackEngine(player, {
        onError: (operation, error) => log.warn(`Error during AVPlayer ${operation}:`, error),
      });
    }

    // Decrement live-instance counter and only close the shared
    // AudioContext when the last AVPlayer is gone.
    if (this._instanceCounted && this._runtime?._avplayerInstanceCount > 0) {
      this._runtime._avplayerInstanceCount -= 1;
      this._instanceCounted = false;
    }

    // Cleanup AudioContext to free memory
    // Only close if we created it and no other AVPlayer instances are using it
    if (this._runtime?.AVPlayer?.audioContext && !this._runtime._avplayerInstanceCount) {
      try {
        const audioCtx = this._runtime.AVPlayer.audioContext;
        if (audioCtx.state !== "closed") {
          // Suspend first, then close
          if (audioCtx.state === "running") {
            await audioCtx.suspend();
          }
          await audioCtx.close();
          this._runtime.AVPlayer.audioContext = null;
          log.debug("AudioContext closed");
        }
      } catch (e) {
        log.warn("Error closing AudioContext:", e);
      }
    }

    this.isReady = false;
    this._playing = false;
    this._currentTimeMs = 0;
    this._durationMs = 0;
    log.debug("Destroyed");
  }
}
