import { getEnvInfo, avplayerLogger as log } from "../core/logger.js";
import { getPlaybackResourcePolicy } from "../player/playback_environment.js";
import { detectWebCodecsSupport } from "./codec_detector.js";
import {
  AVPLAYER_CONFIG,
  DECODER_WASM_FILES,
  getAvPlayerScriptUrls,
  getWasmUrl as getWasmUrlFromConfig,
  OTHER_WASM_FILES,
} from "./config.js";

// Cache for tested local WASM availability
const localWasmAvailable = new Map();

// Cache for pre-loaded WASM modules
const preloadedWasm = new Map();

// Cache in-flight script loads so concurrent AVPlayer probes/instances do not
// append duplicate UMD scripts or race against partially initialized globals.
const scriptLoadPromises = new Map();

export function configureLibmediaLogging() {
  // libmedia reads COMMON_LOG_LEVEL from the global object. Keep its noisy
  // demux/decode info out of production consoles, but preserve it in debug.
  window.COMMON_LOG_LEVEL = getEnvInfo().isDev || window.__STREAMIX_DEBUG__ ? 2 : 4;
}

// Codec IDs from @libmedia/avutil
export const AVCodecID = {
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
export function getWasmUrl(type, codecId) {
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
  const commonCodecs = [AVCodecID.AV_CODEC_ID_AAC, AVCodecID.AV_CODEC_ID_H264];

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
        log.debug(`Pre-loaded WASM codec: ${codecId}`);
      }
    } catch (e) {
      // Silently fail - pre-loading is optional optimization
      log.debug(`Pre-load failed for codec ${codecId}:`, e.message);
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

  // Pre-load the stretchpitcher too. libmedia pulls it during audio
  // pipeline init right before the first GET — when it isn't cached the
  // worker stalls inside an Atomics.wait waiting for the fetch, and our
  // 60 s wrapper timeout fires before any byte of the moov is requested.
  // Field repro on movie 141 was: HEAD → 60 s silence → timeout → reset
  // → second attempt fetches stretchpitch and only then issues GETs.
  // Caching it up front skips that whole loop.
  const stretchpitchUrl = getWasmUrl("stretchpitcher");
  if (stretchpitchUrl && !preloadedWasm.has(stretchpitchUrl)) {
    preloadPromises.push(
      fetch(stretchpitchUrl, { method: "GET", cache: "force-cache", priority: "low" })
        .then((r) => (r.ok ? r.arrayBuffer() : null))
        .then((buf) => (buf ? WebAssembly.compile(buf) : null))
        .then((mod) => mod && preloadedWasm.set(stretchpitchUrl, mod))
        .catch(() => {}),
    );
  }

  await Promise.allSettled(preloadPromises);
  log.debug(`Pre-loaded ${preloadedWasm.size} WASM modules`);
}

/**
 * Load a script dynamically
 */
export function loadScript(src, id = null) {
  const key = id || src;

  if (scriptLoadPromises.has(key)) {
    return scriptLoadPromises.get(key);
  }
  if (id && document.getElementById(id)) {
    return Promise.resolve();
  }

  const promise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    if (id) script.id = id;
    script.src = src;
    script.onload = () => {
      scriptLoadPromises.delete(key);
      resolve();
    };
    script.onerror = () => {
      scriptLoadPromises.delete(key);
      script.remove();
      reject(new Error(`Failed to load script: ${src}`));
    };
    document.head.appendChild(script);
  });

  scriptLoadPromises.set(key, promise);
  return promise;
}

/** Warm static dependencies on intent; AudioContext and media remain owned by activation. */
export async function preloadAVPlayerRuntime(context = {}, dependencies = {}) {
  const policy = dependencies.getResourcePolicy || getPlaybackResourcePolicy;
  if (policy().avoidSpeculativeWork) return;
  const configure = dependencies.configureRuntime || configureWebpackPublicPath;
  const scripts = dependencies.getScriptUrls || getAvPlayerScriptUrls;
  const load = dependencies.loadScript || loadScript;
  const wasm = dependencies.preloadWasm || preloadCommonWasm;
  configure();
  const urls = scripts();
  await Promise.all([
    load(urls.polyfill, "cheap-polyfill").then(() => load(urls.player, "avplayer-script")),
    wasm(context),
  ]);
}

/**
 * Configure webpack public path for dynamic imports
 * AVPlayer UMD bundle loads chunks dynamically and needs to know the base path
 *
 * Note: This is set globally once and checked before setting to avoid conflicts
 * with other modules that might use webpack dynamic imports.
 */
export function configureWebpackPublicPath() {
  // Only set if not already configured (prevents conflicts with other modules)
  if (typeof __webpack_public_path__ === "undefined") {
    window.__webpack_public_path__ = `${AVPLAYER_CONFIG.scriptBasePath}/`;
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
