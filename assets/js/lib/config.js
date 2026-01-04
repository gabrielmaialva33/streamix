/**
 * Player Configuration
 *
 * Centralized configuration for the video player.
 * URLs and settings can be overridden via environment variables at build time.
 */

// AVPlayer local paths (bundled with app)
export const AVPLAYER_CONFIG = {
  // Local base path for AVPlayer assets
  localBasePath: '/avplayer',

  // CDN base URL for WASM files (fallback if local not available)
  cdnBasePath: 'https://cdn.jsdelivr.net/gh/zhaohappy/libmedia@latest/dist',

  // Whether to prefer local assets over CDN (more secure, no SRI needed)
  preferLocal: true,

  // WASM file paths (relative to base path)
  wasmPaths: {
    decode: '/decode',
    resample: '/resample',
    stretchpitch: '/stretchpitch',
  },

  // Script paths (always loaded locally)
  scripts: {
    polyfill: '/cheap-polyfill.js',
    player: '/avplayer.js',
  },
};

// Codec ID to WASM file mapping
export const DECODER_WASM_FILES = {
  // Audio decoders
  aac: 'aac-atomic.wasm',
  mp3: 'mp3-atomic.wasm',
  flac: 'flac-atomic.wasm',
  opus: 'opus-atomic.wasm',
  vorbis: 'vorbis-atomic.wasm',
  ac3: 'ac3-atomic.wasm',
  eac3: 'eac3-atomic.wasm',
  dca: 'dca-atomic.wasm', // DTS
  pcm: 'pcm-atomic.wasm',
  adpcm: 'adpcm-atomic.wasm',

  // Video decoders
  h264: 'h264-atomic.wasm',
  hevc: 'hevc-atomic.wasm',
  vp9: 'vp9-atomic.wasm',
  vp8: 'vp8-atomic.wasm',
  av1: 'av1-atomic.wasm',
  mpeg4: 'mpeg4-atomic.wasm',
  mpeg2video: 'mpeg2video-atomic.wasm',
};

// Other WASM files
export const OTHER_WASM_FILES = {
  resampler: 'resample-atomic.wasm',
  stretchpitcher: 'stretchpitch-atomic.wasm',
};

/**
 * Get the full URL for a WASM file
 * Tries local first, falls back to CDN
 *
 * @param {string} type - 'decoder', 'resampler', or 'stretchpitcher'
 * @param {string} filename - WASM filename
 * @param {boolean} useCdn - Force CDN usage
 * @returns {string} Full URL to WASM file
 */
export function getWasmUrl(type, filename, useCdn = false) {
  const config = AVPLAYER_CONFIG;

  if (config.preferLocal && !useCdn) {
    // Use local path
    let subPath;
    switch (type) {
      case 'decoder':
        subPath = config.wasmPaths.decode;
        break;
      case 'resampler':
        subPath = config.wasmPaths.resample;
        break;
      case 'stretchpitcher':
        subPath = config.wasmPaths.stretchpitch;
        break;
      default:
        subPath = config.wasmPaths.decode;
    }
    return `${config.localBasePath}${subPath}/${filename}`;
  }

  // Use CDN path
  let cdnSubPath;
  switch (type) {
    case 'decoder':
      cdnSubPath = '/decode';
      break;
    case 'resampler':
      cdnSubPath = '/resample';
      break;
    case 'stretchpitcher':
      cdnSubPath = '/stretchpitch';
      break;
    default:
      cdnSubPath = '/decode';
  }
  return `${config.cdnBasePath}${cdnSubPath}/${filename}`;
}

/**
 * Get AVPlayer script URLs
 * @returns {{ polyfill: string, player: string }}
 */
export function getAvPlayerScriptUrls() {
  const config = AVPLAYER_CONFIG;
  return {
    polyfill: `${config.localBasePath}${config.scripts.polyfill}`,
    player: `${config.localBasePath}${config.scripts.player}`,
  };
}

export default {
  AVPLAYER_CONFIG,
  DECODER_WASM_FILES,
  OTHER_WASM_FILES,
  getWasmUrl,
  getAvPlayerScriptUrls,
};
