/**
 * AVPlayer Wrapper for libmedia
 *
 * Provides software decoding for codecs not supported by browsers,
 * including AC3, DTS, EAC3 (Dolby Digital).
 */

import { avplayerLogger as log } from "./logger";
import { detectWebCodecsSupport } from "./codec_detector";
import {
  AVPLAYER_CONFIG,
  DECODER_WASM_FILES,
  getAvPlayerScriptUrls,
  getWasmUrl as getWasmUrlFromConfig,
  OTHER_WASM_FILES,
} from "./config";

// Cache for tested local WASM availability
const localWasmAvailable = new Map();

// Cache for pre-loaded WASM modules
const preloadedWasm = new Map();

// Track active audio detection to prevent AudioContext leaks during rapid zapping
let activeAudioDetection = null;

// AVMediaType constants from libmedia
const _AVMediaType = {
  AVMEDIA_TYPE_VIDEO: 0,
  AVMEDIA_TYPE_AUDIO: 1,
  AVMEDIA_TYPE_DATA: 2,
  AVMEDIA_TYPE_SUBTITLE: 3,
  AVMEDIA_TYPE_ATTACHMENT: 4,
};

// Codec IDs from @libmedia/avutil
const AVCodecID = {
  // Audio codecs
  AV_CODEC_ID_AAC: 86018,
  AV_CODEC_ID_MP3: 86017,
  AV_CODEC_ID_FLAC: 86028,
  AV_CODEC_ID_OPUS: 86076,
  AV_CODEC_ID_VORBIS: 86021,
  AV_CODEC_ID_AC3: 86019,
  AV_CODEC_ID_EAC3: 86056,
  AV_CODEC_ID_DTS: 86020, // DCA
  AV_CODEC_ID_PCM_S16LE: 65536,
  AV_CODEC_ID_PCM_S24LE: 65540,
  // Video codecs
  AV_CODEC_ID_H264: 27,
  AV_CODEC_ID_HEVC: 173,
  AV_CODEC_ID_VP9: 167,
  AV_CODEC_ID_VP8: 139,
  AV_CODEC_ID_AV1: 225,
  AV_CODEC_ID_MPEG4: 12,
  AV_CODEC_ID_MPEG2VIDEO: 2,
};

// Map codec IDs to WASM file names
const DECODER_WASM_MAP = {
  // Audio decoders
  [AVCodecID.AV_CODEC_ID_AAC]: "aac",
  [AVCodecID.AV_CODEC_ID_MP3]: "mp3",
  [AVCodecID.AV_CODEC_ID_FLAC]: "flac",
  [AVCodecID.AV_CODEC_ID_OPUS]: "opus",
  [AVCodecID.AV_CODEC_ID_VORBIS]: "vorbis",
  [AVCodecID.AV_CODEC_ID_AC3]: "ac3",
  [AVCodecID.AV_CODEC_ID_EAC3]: "eac3",
  [AVCodecID.AV_CODEC_ID_DTS]: "dca", // DTS uses dca (DTS Coherent Acoustics)
  [AVCodecID.AV_CODEC_ID_PCM_S16LE]: "pcm",
  [AVCodecID.AV_CODEC_ID_PCM_S24LE]: "pcm",
  // Video decoders
  [AVCodecID.AV_CODEC_ID_H264]: "h264",
  [AVCodecID.AV_CODEC_ID_HEVC]: "hevc",
  [AVCodecID.AV_CODEC_ID_VP9]: "vp9",
  [AVCodecID.AV_CODEC_ID_VP8]: "vp8",
  [AVCodecID.AV_CODEC_ID_AV1]: "av1",
  [AVCodecID.AV_CODEC_ID_MPEG4]: "mpeg4",
  [AVCodecID.AV_CODEC_ID_MPEG2VIDEO]: "mpeg2video",
};

// PCM codec range
const PCM_CODEC_START = 65536;
const PCM_CODEC_END = 65572;
const ADPCM_CODEC_START = 69632;
const ADPCM_CODEC_END = 69683;

/**
 * Get WASM URL for a given codec
 * Uses local files first, falls back to CDN if local not available
 */
function getWasmUrl(type, codecId) {
  let filename;

  // Handle resampler and stretchpitcher FIRST - they don't need a codecId
  if (type === "resampler") {
    filename = OTHER_WASM_FILES.resampler;
    return getWasmUrlWithFallback("resampler", filename);
  }
  if (type === "stretchpitcher") {
    filename = OTHER_WASM_FILES.stretchpitcher;
    return getWasmUrlWithFallback("stretchpitcher", filename);
  }

  // For decoder type, we need a valid codecId
  if (type !== "decoder") {
    log.warn(`Unknown WASM type: ${type}`);
    return null;
  }

  // Handle PCM range
  if (codecId >= PCM_CODEC_START && codecId <= PCM_CODEC_END) {
    filename = DECODER_WASM_FILES.pcm;
    return getWasmUrlWithFallback("decoder", filename);
  }
  // Handle ADPCM range
  if (codecId >= ADPCM_CODEC_START && codecId <= ADPCM_CODEC_END) {
    filename = DECODER_WASM_FILES.adpcm;
    return getWasmUrlWithFallback("decoder", filename);
  }

  const codecName = DECODER_WASM_MAP[codecId];
  if (!codecName) {
    log.warn(`Unknown codec ID: ${codecId}`);
    return null;
  }

  filename = DECODER_WASM_FILES[codecName];
  if (!filename) {
    // Fallback to constructing filename
    filename = `${codecName}-atomic.wasm`;
  }

  return getWasmUrlWithFallback("decoder", filename);
}

/**
 * Get WASM URL with fallback to CDN if local not available
 * Checks if local file exists and caches the result
 */
function getWasmUrlWithFallback(type, filename) {
  const localUrl = getWasmUrlFromConfig(type, filename, false);
  const cdnUrl = getWasmUrlFromConfig(type, filename, true);

  // If we've already tested this URL, return based on cached result
  if (localWasmAvailable.has(localUrl)) {
    return localWasmAvailable.get(localUrl) ? localUrl : cdnUrl;
  }

  // For first request, prefer local and let it fall back on error
  // The browser will cache the HEAD request result
  if (AVPLAYER_CONFIG.preferLocal) {
    // Async check if local file exists (for future requests)
    checkLocalWasmAvailability(localUrl).then((available) => {
      localWasmAvailable.set(localUrl, available);
      if (!available) {
        log.warn(`Local WASM not available, will use CDN: ${filename}`);
      }
    });

    return localUrl;
  }

  return cdnUrl;
}

/**
 * Check if a local WASM file is available via HEAD request
 */
async function checkLocalWasmAvailability(url) {
  try {
    const response = await fetch(url, { method: "HEAD" });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Pre-load common WASM decoders to reduce startup latency
 * Call this early (on hover, page load, etc.) to have decoders ready
 */
export async function preloadCommonWasm({ stream_type, source_type } = {}) {
  // Default narrow set: every IPTV stream we serve has H.264 + AAC at
  // minimum, that's the only thing worth pre-fetching unconditionally
  // (~1 MB of WASM total). Older `preloadCommonWasm()` greedily fetched
  // AC3/EAC3/DTS/HEVC up front for every viewer — that's 5-10 MB of
  // unused bandwidth on the typical playback.
  const commonCodecs = [
    AVCodecID.AV_CODEC_ID_AAC,
    AVCodecID.AV_CODEC_ID_H264,
  ];

  // Only opt into the expensive audio decoders when the player is
  // about to play content known to need them. GIndex (MKV/HEVC) is the
  // canonical case; for everything else we lazy-load on first need.
  if (source_type === "gindex" || stream_type === "mkv" || stream_type === "hevc") {
    commonCodecs.push(
      AVCodecID.AV_CODEC_ID_HEVC,
      AVCodecID.AV_CODEC_ID_AC3,
      AVCodecID.AV_CODEC_ID_EAC3,
      AVCodecID.AV_CODEC_ID_DTS,
      AVCodecID.AV_CODEC_ID_MP3,
    );
  }

  const preloadPromises = commonCodecs.map(async (codecId) => {
    const url = getWasmUrl("decoder", codecId);
    if (!url || preloadedWasm.has(url)) return;

    try {
      // Use fetch with cache to pre-load the WASM file
      const response = await fetch(url, {
        method: "GET",
        cache: "force-cache",
        priority: "low",
      });
      if (response.ok) {
        // Compile the WASM module ahead of time for even faster startup
        const buffer = await response.arrayBuffer();
        const module = await WebAssembly.compile(buffer);
        preloadedWasm.set(url, module);
        log.debug(`Pre-loaded WASM: ${url.split("/").pop()}`);
      }
    } catch (e) {
      // Silently fail - pre-loading is optional optimization
      log.debug(`Pre-load failed for ${url}:`, e.message);
    }
  });

  // Also pre-load resampler
  const resamplerUrl = getWasmUrl("resampler");
  if (resamplerUrl && !preloadedWasm.has(resamplerUrl)) {
    preloadPromises.push(
      fetch(resamplerUrl, { method: "GET", cache: "force-cache", priority: "low" })
        .then((r) => (r.ok ? r.arrayBuffer() : null))
        .then((buf) => (buf ? WebAssembly.compile(buf) : null))
        .then((mod) => mod && preloadedWasm.set(resamplerUrl, mod))
        .catch(() => {}),
    );
  }

  await Promise.allSettled(preloadPromises);
  log.debug(`Pre-loaded ${preloadedWasm.size} WASM modules`);
}

/**
 * Load a script dynamically
 */
function loadScript(src, id = null) {
  return new Promise((resolve, reject) => {
    // Check if already loaded
    if (id && document.getElementById(id)) {
      resolve();
      return;
    }

    const script = document.createElement("script");
    if (id) script.id = id;
    script.src = src;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`Failed to load script: ${src}`));
    document.head.appendChild(script);
  });
}

/**
 * Configure webpack public path for dynamic imports
 * AVPlayer UMD bundle loads chunks dynamically and needs to know the base path
 *
 * Note: This is set globally once and checked before setting to avoid conflicts
 * with other modules that might use webpack dynamic imports.
 */
function configureWebpackPublicPath() {
  // Only set if not already configured (prevents conflicts with other modules)
  if (typeof __webpack_public_path__ === "undefined") {
    window.__webpack_public_path__ = `${AVPLAYER_CONFIG.localBasePath}/`;
    log.debug("Webpack public path configured:", window.__webpack_public_path__);
  }
}

/**
 * Prefer the browser's native decode pipeline when the full WebCodecs
 * decode path is available; otherwise fall back to the existing WASM path.
 *
 * libmedia treats `enableHardware` and `enableWebCodecs` as independent
 * toggles — the previous coupling forced both on/off together, hiding
 * the case where a UA has WebCodecs but no usable hardware decoder for
 * the codec at hand (Linux Chrome with HEVC, for instance).
 */
export function getAVPlayerAccelerationConfig() {
  const webCodecs = detectWebCodecsSupport();
  const hasWebCodecs =
    webCodecs.features.videoDecoder &&
    webCodecs.features.audioDecoder &&
    webCodecs.features.videoFrame &&
    typeof EncodedVideoChunk !== "undefined" &&
    typeof EncodedAudioChunk !== "undefined";

  // Hardware acceleration is gated by both WebCodecs availability AND
  // whether the host actually offers GPU video decoding. We can't
  // perfectly probe this synchronously — `MediaCapabilities` would be
  // the right call but it's async — so use WebCodecs as a strong
  // proxy: if the platform exposes WebCodecs at all it usually has
  // hardware decode for h264 + aac, the codecs we care about most.
  const hasHardware = hasWebCodecs;

  return {
    enableWebCodecs: hasWebCodecs,
    enableHardware: hasHardware,
    mode: hasWebCodecs ? "webcodecs-hardware-preferred" : "wasm-fallback",
  };
}

/**
 * AVPlayer wrapper class
 */
// libmedia's FetchIOLoader has a bug: HTTP-level errors like 502/503/504
// are logged as fatal and never retried. Its `retryCount: 20` default
// only kicks in for fetch() *exceptions* (network drops), not for
// non-2xx responses. Choki sometimes returns transient 502/504 on
// vauth chain hops, and we'd see the player freeze on every burst.
//
// Patch `window.fetch` once, *only* for requests that target our IPTV
// proxy hosts, to retry on 5xx with exponential backoff. Other fetches
// on the page (LiveView, image proxy, TMDB) are untouched.
function installRetryingFetch() {
  if (window.__streamixFetchPatched) return;
  window.__streamixFetchPatched = true;

  const RETRYABLE = new Set([502, 503, 504]);
  // 4 attempts with 200ms base = up to 1.4s total (200 + 400 + 800ms).
  // Originally 6×250ms (≈16s of spinner). The choki vauth hop usually
  // recovers within the first or second retry; if it doesn't, the
  // user is better served by getting an error fast and letting AVPlayer
  // restart from a fresh URL than staring at a frozen frame for 16s.
  const MAX_ATTEMPTS = 4;
  const BASE_BACKOFF_MS = 200;
  const SHOULD_INTERCEPT = (url) => {
    try {
      const u = typeof url === "string" ? url : url.url;
      return /\/proxy\?url=|source\d?\.mahina\.cloud|streamix\.mahina\.cloud\/api\/stream\//.test(u);
    } catch {
      return false;
    }
  };

  const originalFetch = window.fetch.bind(window);
  window.fetch = async function patchedFetch(input, init) {
    if (!SHOULD_INTERCEPT(input)) {
      return originalFetch(input, init);
    }

    let lastResponse = null;
    let attempt = 0;
    while (attempt < MAX_ATTEMPTS) {
      const res = await originalFetch(input, init);
      if (!RETRYABLE.has(res.status)) {
        return res;
      }
      lastResponse = res;
      // Drain body so the connection can be reused.
      try {
        await res.arrayBuffer();
      } catch {
      }
      attempt++;
      if (attempt >= MAX_ATTEMPTS) break;
      const delay = BASE_BACKOFF_MS * Math.pow(2, attempt - 1);
      log.warn(
        `[StreamFetch] ${res.status} from upstream, retry ${attempt}/${MAX_ATTEMPTS} in ${delay}ms`,
      );
      await new Promise((r) => setTimeout(r, delay));
    }
    log.error(
      `[StreamFetch] gave up after ${MAX_ATTEMPTS} retries, returning last ${lastResponse?.status}`,
    );
    return lastResponse;
  };
}

installRetryingFetch();

export class AVPlayerWrapper {
  constructor(options = {}) {
    this.container = options.container;
    this.onError = options.onError || (() => {});
    this.onReady = options.onReady || (() => {});
    this.onPlay = options.onPlay || (() => {});
    this.onPause = options.onPause || (() => {});
    this.onTimeUpdate = options.onTimeUpdate || (() => {});
    this.onEnded = options.onEnded || (() => {});

    this.player = null;
    this.isReady = false;
    this.currentUrl = null;
    this._destroyed = false;

    // Internal state for tracking playback
    this._playing = false;
    this._currentTimeMs = 0;
    this._durationMs = 0;
    this._volume = 1;
  }

  /**
   * Initialize the AVPlayer with all required dependencies
   */
  async init() {
    if (this.player || this._destroyed) {
      return;
    }

    try {
      log.debug("Initializing...");

      // Step 1: Configure webpack public path for dynamic chunk loading
      configureWebpackPublicPath();

      // Step 2: Get script URLs from config
      const scriptUrls = getAvPlayerScriptUrls();

      // Step 3: Load cheap-polyfill.js FIRST
      await loadScript(scriptUrls.polyfill, "cheap-polyfill");
      log.debug("Loaded cheap-polyfill.js");

      // Step 4: Configure polyfill URL for BigInt fallback
      if (typeof BigInt === "undefined" || BigInt === Number) {
        window.CHEAP_POLYFILL_URL = scriptUrls.polyfill;
      }

      // Step 5: Load AVPlayer main script
      await loadScript(scriptUrls.player);
      log.debug("Loaded avplayer.js");

      if (!window.AVPlayer) {
        throw new Error("AVPlayer not found after loading script");
      }

      // Step 5: Initialize AudioContext (required for Web Audio API playback)
      if (!window.AVPlayer.audioContext) {
        window.AVPlayer.audioContext = new (window.AudioContext || window.webkitAudioContext)();
        // Create a dummy source to unlock audio on mobile
        window.AVPlayer.audioContext.createBufferSource();
        log.debug("AudioContext initialized");
      }

      const accelerationConfig = getAVPlayerAccelerationConfig();
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
        /Android|iPhone|iPad/i.test(navigator.userAgent) &&
        (navigator.hardwareConcurrency || 4) <= 4;
      const audioWorkletBufferLength = isLowEndMobile ? 10 : 6;

      // Jitter buffer: previously hard-pinned to 0.2-1s for "tight sync".
      // That works on a clean desktop network but starves on flaky
      // mobile, especially when the proxy chain is slow. Use a relaxed
      // default and only tighten on capable hardware.
      const jitterBufferMin = isLowEndMobile ? 0.5 : 0.3;
      const jitterBufferMax = isLowEndMobile ? 3 : 1.5;

      this.player = new window.AVPlayer({
        container: this.container,
        getWasm: (type, codecId) => {
          const url = getWasmUrl(type, codecId);
          log.debug(`getWasm: type=${type}, codecId=${codecId}, url=${url}`);
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

      // Set up event listeners
      this.setupEventListeners();

      // Track live AVPlayer instances so we don't close the shared
      // AudioContext while another player still needs it (probe +
      // main, watch-party rejoin races).
      window._avplayerInstanceCount = (window._avplayerInstanceCount || 0) + 1;

      this.isReady = true;
      this.onReady();

      log.debug("Initialized successfully");
    } catch (error) {
      log.error("Failed to initialize:", error);
      this.onError(error);
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
      this.onError(error);
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
      throw new Error("Player has been destroyed");
    }

    if (!this.player) {
      await this.init();
    }

    this.currentUrl = url;
    log.debug("Loading:", url);
    log.debug("Load options:", options);
    log.debug("Container:", this.container);
    log.debug("Player instance:", this.player);

    try {
      log.debug("Calling player.load()...");

      // Create a timeout promise to detect if load hangs
      const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error("Load timeout after 30 seconds")), 30000);
      });

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
      this._isLive = !!options.isLive;

      const loadResult = this.player.load(url, loadOptions);
      log.debug("load() returned:", loadResult);

      if (loadResult && typeof loadResult.then === "function") {
        // Race between load and timeout
        await Promise.race([loadResult, timeoutPromise]);
      }

      log.debug("Load complete");
    } catch (error) {
      log.error("Load error:", error);
      log.error("Error stack:", error?.stack);
      this.onError(error);
      throw error;
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
      // `subtitle: true` belongs here, not on the constructor (libmedia
      // 1.3 typings put it on AVPlayerPlayOptions). Audio + video are
      // on by default.
      const playResult = this.player.play({ subtitle: true });
      log.debug("player.play() returned:", playResult);
      if (playResult && typeof playResult.then === "function") {
        await playResult;
      }
      // Manually set _playing in case event doesn't fire
      this._playing = true;
      log.debug("play() completed successfully, _playing:", this._playing);
      // Manually call onPlay since event might not fire on resume
      this.onPlay();
    } catch (error) {
      log.error("Play error:", error);
      this.onError(error);
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
    if (this.player) {
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
    if (!this.player) return [];

    try {
      // Method 1: Try AVPlayer's getAudioList (for HLS/DASH)
      if (typeof this.player.getAudioList === "function") {
        const result = await this.player.getAudioList();
        if (result?.list && result.list.length > 0) {
          return result.list.map((track, index) => ({
            id: track.id ?? index,
            index,
            label: track.name || track.title || `Audio ${index + 1}`,
            language: track.lang || track.language || "",
            selected: index === result.selectedIndex,
          }));
        }
      }

      // Method 2: For MP4/MKV, use selectedAudioStream and formatContext
      // codecpar is a pointer in libmedia, so we use metadata to identify tracks
      const formatContext = this.player.getFormatContext?.();
      const selectedAudio = this.player.selectedAudioStream;
      const selectedVideo = this.player.selectedVideoStream;

      if (formatContext?.streams) {
        const audioTracks = [];
        const videoStreamIds = new Set();

        // First, identify video streams by selectedVideoStream
        if (selectedVideo) {
          videoStreamIds.add(selectedVideo.id);
        }

        // Identify audio streams - those that aren't video and have audio-like metadata
        formatContext.streams.forEach((stream) => {
          // Skip if it's the selected video stream
          if (videoStreamIds.has(stream.id)) return;

          // Check if this could be an audio stream based on metadata
          const metadata = stream.metadata || {};
          const title = metadata.title || "";
          const bps = parseInt(metadata.BPS, 10) || 0;

          // Audio streams typically have lower BPS than video (< 1Mbps usually)
          // Video streams typically have BPS > 1Mbps
          const isLikelyAudio = bps > 0 && bps < 1500000;

          // Also check if it's the selected audio stream
          const isSelectedAudio = selectedAudio && selectedAudio.id === stream.id;

          if (isSelectedAudio || isLikelyAudio) {
            audioTracks.push({
              id: stream.id,
              index: audioTracks.length,
              streamIndex: stream.index,
              label: title || `Audio ${audioTracks.length + 1}`,
              language: metadata.language || "",
              selected: isSelectedAudio,
            });
          }
        });

        // If we found no tracks but hasAudio is true, add the selected stream
        if (audioTracks.length === 0 && this.player.hasAudio?.() && selectedAudio) {
          const metadata = selectedAudio.metadata || {};
          audioTracks.push({
            id: selectedAudio.id,
            index: 0,
            streamIndex: selectedAudio.index,
            label: metadata.title || "Audio 1",
            language: metadata.language || "",
            selected: true,
          });
        }

        return audioTracks;
      }
    } catch (e) {
      log.warn("Error getting audio tracks:", e);
    }

    return [];
  }

  /**
   * Get list of subtitle tracks from the media
   * @returns {Array} Array of subtitle track objects with id, index, label, language
   */
  async getSubtitleTracks() {
    if (!this.player) return [];

    try {
      // Method 1: Try AVPlayer's getSubtitleList (for HLS/DASH)
      if (typeof this.player.getSubtitleList === "function") {
        const result = await this.player.getSubtitleList();
        if (result?.list && result.list.length > 0) {
          return result.list.map((track, index) => ({
            id: track.id ?? index,
            index,
            label: track.name || track.title || `Subtitle ${index + 1}`,
            language: track.lang || track.language || "",
            selected: index === result.selectedIndex,
          }));
        }
      }

      // Method 2: For MP4/MKV, use selectedSubtitleStream and formatContext
      const formatContext = this.player.getFormatContext?.();
      const selectedSub = this.player.selectedSubtitleStream;
      const selectedVideo = this.player.selectedVideoStream;
      const selectedAudio = this.player.selectedAudioStream;

      if (formatContext?.streams) {
        const subtitleTracks = [];
        const usedStreamIds = new Set();

        // Mark video and audio streams as used
        if (selectedVideo) usedStreamIds.add(selectedVideo.id);
        if (selectedAudio) usedStreamIds.add(selectedAudio.id);

        // Remaining streams that aren't video/audio could be subtitles
        formatContext.streams.forEach((stream) => {
          // Skip video and audio streams
          if (usedStreamIds.has(stream.id)) return;

          const metadata = stream.metadata || {};
          const bps = parseInt(metadata.BPS, 10) || 0;

          // Subtitle streams typically have very low or zero BPS
          // They're text-based so they're much smaller than audio
          const isLikelySubtitle = bps === 0 || bps < 50000;
          const isSelectedSub = selectedSub && selectedSub.id === stream.id;

          if (isSelectedSub || isLikelySubtitle) {
            subtitleTracks.push({
              id: stream.id,
              index: subtitleTracks.length,
              streamIndex: stream.index,
              label: metadata.title || `Subtitle ${subtitleTracks.length + 1}`,
              language: metadata.language || "",
              selected: isSelectedSub,
            });
          }
        });

        // If hasSubtitle but we found nothing, add selected subtitle
        if (subtitleTracks.length === 0 && this.player.hasSubtitle?.() && selectedSub) {
          const metadata = selectedSub.metadata || {};
          subtitleTracks.push({
            id: selectedSub.id,
            index: 0,
            streamIndex: selectedSub.index,
            label: metadata.title || "Subtitle 1",
            language: metadata.language || "",
            selected: true,
          });
        }

        return subtitleTracks;
      }
    } catch (e) {
      log.warn("Error getting subtitle tracks:", e);
    }

    return [];
  }

  /**
   * Select an audio track by ID
   * @param {number} trackId - The track ID to select
   */
  async selectAudioTrack(trackId) {
    if (!this.player) return;

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
    if (!this.player) return;

    try {
      log.debug(`Selecting subtitle track: ${trackId}`);
      if (trackId === -1) {
        // Disable subtitles - libmedia may have a specific method for this
        // For now, we'll try selectSubtitle with -1 or a special value
        if (typeof this.player.hideSubtitle === "function") {
          await this.player.hideSubtitle();
        } else {
          await this.player.selectSubtitle(-1);
        }
      } else {
        await this.player.selectSubtitle(trackId);
      }
      log.debug(`Subtitle track ${trackId} selected`);
    } catch (e) {
      log.error("Error selecting subtitle track:", e);
      throw e;
    }
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

    if (this.player) {
      try {
        await this.player.destroy();
      } catch (e) {
        log.warn("Error during destroy:", e);
      }
      this.player = null;
    }

    // Decrement live-instance counter and only close the shared
    // AudioContext when the last AVPlayer is gone.
    if (this.isReady && window._avplayerInstanceCount > 0) {
      window._avplayerInstanceCount -= 1;
    }

    // Cleanup AudioContext to free memory
    // Only close if we created it and no other AVPlayer instances are using it
    if (window.AVPlayer?.audioContext && !window._avplayerInstanceCount) {
      try {
        const audioCtx = window.AVPlayer.audioContext;
        if (audioCtx.state !== "closed") {
          // Suspend first, then close
          if (audioCtx.state === "running") {
            await audioCtx.suspend();
          }
          await audioCtx.close();
          window.AVPlayer.audioContext = null;
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

/**
 * Detect if a video element has audio issues
 * Returns true if audio is not working properly
 */
export function detectAudioIssue(videoElement) {
  return new Promise((resolve) => {
    // Quick timeout - don't wait too long
    const timeout = setTimeout(() => {
      log.debug("[detectAudioIssue] Timeout - assuming no issue");
      resolve(false);
    }, 5000);

    // Method 1: Check webkitAudioDecodedByteCount (Chrome/Safari)
    if ("webkitAudioDecodedByteCount" in videoElement) {
      const checkAudio = () => {
        // Wait for video to play for a bit
        if (videoElement.currentTime > 0.5) {
          clearTimeout(timeout);
          const hasAudio = videoElement.webkitAudioDecodedByteCount > 0;
          log.debug(`[detectAudioIssue] webkitAudioDecodedByteCount: ${videoElement.webkitAudioDecodedByteCount}, hasAudio: ${hasAudio}`);
          resolve(!hasAudio);
        } else if (!videoElement.paused) {
          requestAnimationFrame(checkAudio);
        }
      };

      if (videoElement.readyState >= 3 && !videoElement.paused) {
        setTimeout(checkAudio, 300);
      } else {
        const onPlaying = () => {
          videoElement.removeEventListener("playing", onPlaying);
          setTimeout(checkAudio, 300);
        };
        videoElement.addEventListener("playing", onPlaying);
      }
      return;
    }

    // Method 2: Check audioTracks (Firefox)
    if (videoElement.audioTracks) {
      const checkTracks = () => {
        clearTimeout(timeout);
        const hasAudioTracks = videoElement.audioTracks.length > 0;
        log.debug(`[detectAudioIssue] audioTracks count: ${videoElement.audioTracks.length}`);
        resolve(!hasAudioTracks);
      };

      if (videoElement.readyState >= 1) {
        checkTracks();
      } else {
        videoElement.addEventListener("loadedmetadata", checkTracks, { once: true });
      }
      return;
    }

    // Method 3: Web Audio API fallback (works on all browsers)
    // Creates an AudioContext and analyzes the audio stream from the video
    detectAudioWithWebAudioAPI(videoElement)
      .then((hasAudio) => {
        clearTimeout(timeout);
        log.debug(`[detectAudioIssue] Web Audio API detection: hasAudio=${hasAudio}`);
        resolve(!hasAudio);
      })
      .catch((error) => {
        log.warn("[detectAudioIssue] Web Audio API detection failed:", error);
        clearTimeout(timeout);
        resolve(false); // Assume no issue on error
      });
  });
}

/**
 * Detect audio using Web Audio API
 * Creates an AnalyserNode to check for actual audio data in the stream
 * Supports cancellation to prevent AudioContext leaks during rapid channel switching
 */
function detectAudioWithWebAudioAPI(videoElement) {
  // Cancel any active detection to prevent AudioContext accumulation
  if (activeAudioDetection) {
    activeAudioDetection.cancel();
  }

  let cancelled = false;
  let audioContext = null;
  let source = null;
  let timeoutId = null;
  let playingHandler = null;

  const cleanup = () => {
    if (timeoutId) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
    if (playingHandler && videoElement) {
      videoElement.removeEventListener("playing", playingHandler);
      playingHandler = null;
    }
    if (source && audioContext) {
      try {
        source.disconnect();
      } catch (_e) {
        /* ignore */
      }
    }
    if (audioContext) {
      audioContext.close().catch(() => {});
      audioContext = null;
    }
  };

  const detection = {
    cancel: () => {
      cancelled = true;
      cleanup();
      log.debug("[detectAudioWithWebAudioAPI] Detection cancelled");
    },
  };

  activeAudioDetection = detection;

  return new Promise((resolve, reject) => {
    try {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) {
        activeAudioDetection = null;
        reject(new Error("Web Audio API not supported"));
        return;
      }

      audioContext = new AudioContextClass();

      try {
        source = audioContext.createMediaElementSource(videoElement);
      } catch (e) {
        // MediaElementSource may already exist for this element
        log.warn("[detectAudioWithWebAudioAPI] Could not create MediaElementSource:", e);
        cleanup();
        activeAudioDetection = null;
        reject(e);
        return;
      }

      const analyser = audioContext.createAnalyser();
      analyser.fftSize = 256;
      const bufferLength = analyser.frequencyBinCount;
      const dataArray = new Uint8Array(bufferLength);

      // Connect: video -> analyser -> destination (speakers)
      source.connect(analyser);
      analyser.connect(audioContext.destination);

      let checkCount = 0;
      const maxChecks = 10; // Check for ~1 second

      const finishDetection = (hasAudio) => {
        if (cancelled) return;
        // Cleanup: disconnect analyser but keep audio flowing
        try {
          source.disconnect(analyser);
          source.connect(audioContext.destination);
        } catch (_e) {
          /* ignore */
        }
        audioContext.close().catch(() => {});
        audioContext = null;
        activeAudioDetection = null;
        resolve(hasAudio);
      };

      const checkForAudio = () => {
        if (cancelled) return;

        checkCount++;
        analyser.getByteFrequencyData(dataArray);

        // Check if there's any significant audio data
        let sum = 0;
        for (let i = 0; i < bufferLength; i++) {
          sum += dataArray[i];
        }
        const average = sum / bufferLength;

        // If average frequency data is above threshold, audio is present
        if (average > 5) {
          finishDetection(true);
          return;
        }

        if (checkCount < maxChecks && !videoElement.paused && !cancelled) {
          timeoutId = setTimeout(checkForAudio, 100);
        } else if (!cancelled) {
          // No audio detected after all checks
          finishDetection(false);
        }
      };

      // Start checking after a short delay to let audio buffer
      if (videoElement.readyState >= 3 && !videoElement.paused) {
        timeoutId = setTimeout(checkForAudio, 200);
      } else {
        playingHandler = () => {
          if (cancelled) return;
          videoElement.removeEventListener("playing", playingHandler);
          playingHandler = null;
          timeoutId = setTimeout(checkForAudio, 200);
        };
        videoElement.addEventListener("playing", playingHandler);
      }
    } catch (error) {
      cleanup();
      activeAudioDetection = null;
      reject(error);
    }
  });
}

/**
 * Check if browser natively supports a specific audio codec
 */
export function canPlayAudioCodec(codec) {
  const video = document.createElement("video");
  const mimeTypes = {
    ac3: "audio/ac3",
    eac3: "audio/eac3",
    dts: "audio/dts",
    aac: "audio/aac",
    mp3: "audio/mpeg",
    opus: "audio/opus",
    flac: "audio/flac",
    vorbis: 'audio/ogg; codecs="vorbis"',
  };

  const mimeType = mimeTypes[codec.toLowerCase()];
  if (!mimeType) return true; // Unknown codec, assume supported

  const result = video.canPlayType(mimeType);
  return result === "probably" || result === "maybe";
}

export default AVPlayerWrapper;
