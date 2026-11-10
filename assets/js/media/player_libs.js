import { memoizeImport } from "../core/async_primitives.js";
/**
 * Player Libraries Lazy Loader
 *
 * Centralizes dynamic imports for heavy player libraries (hls.js, mpegts.js)
 * so they are only loaded when the player page is actually visited.
 * This keeps the main app.js bundle lean for non-player pages.
 */

import { getEnvInfo } from "../core/logger.js";

let _Hls = null;
let _mpegts = null;

function configureMpegtsLogging(mpegts) {
  const logging = mpegts?.LoggingControl;
  if (!logging || getEnvInfo().isDev || window.__STREAMIX_DEBUG__) return;

  logging.enableVerbose = false;
  logging.enableDebug = false;
  logging.enableInfo = false;
}

const loadHls = memoizeImport(async () => {
  const mod = await import("hls.js");
  _Hls = mod.default;
  return _Hls;
});
const loadMpegts = memoizeImport(async () => {
  const mod = await import("mpegts.js");
  configureMpegtsLogging(mod.default);
  _mpegts = mod.default;
  return _mpegts;
});

export async function getHls() {
  return loadHls();
}
export async function getMpegts() {
  return loadMpegts();
}

/**
 * Check if HLS.js is supported without loading the full library.
 * Replicates the core check from hls.js: MediaSource or ManagedMediaSource support.
 */
export function isHlsJsSupported() {
  if (_Hls) return _Hls.isSupported();

  const mediaSource = window.MediaSource || window.ManagedMediaSource;
  if (!mediaSource) return false;

  // Check for SourceBuffer support (same as hls.js internal check)
  return typeof mediaSource.isTypeSupported === "function";
}

/**
 * Check if mpegts.js MSE live playback is supported without loading the full library.
 * Replicates the core feature check from mpegts.js.
 */
export function isMpegtsSupported() {
  if (_mpegts) return _mpegts.getFeatureList().mseLivePlayback;

  const mediaSource = window.MediaSource || window.ManagedMediaSource;
  if (!mediaSource) return false;

  return typeof mediaSource.isTypeSupported === "function";
}
