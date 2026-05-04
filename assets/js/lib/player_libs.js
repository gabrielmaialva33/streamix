/**
 * Player Libraries Lazy Loader
 *
 * Centralizes dynamic imports for heavy player libraries (hls.js, mpegts.js)
 * so they are only loaded when the player page is actually visited.
 * This keeps the main app.js bundle lean for non-player pages.
 */

import { getEnvInfo } from "./logger";

let _Hls = null;
let _mpegts = null;

function configureMpegtsLogging(mpegts) {
  const logging = mpegts?.LoggingControl;
  if (!logging || getEnvInfo().isDev || window.__STREAMIX_DEBUG__) return;

  logging.enableVerbose = false;
  logging.enableDebug = false;
  logging.enableInfo = false;
}

/**
 * Lazy-load hls.js. Returns the Hls constructor.
 * Cached after first load.
 */
export async function getHls() {
  if (!_Hls) {
    const mod = await import("hls.js");
    _Hls = mod.default;
  }
  return _Hls;
}

/**
 * Lazy-load mpegts.js. Returns the mpegts module.
 * Cached after first load.
 */
export async function getMpegts() {
  if (!_mpegts) {
    const mod = await import("mpegts.js");
    _mpegts = mod.default;
    configureMpegtsLogging(_mpegts);
  }
  return _mpegts;
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

/**
 * Pre-load both libraries in parallel (call when navigating to player page).
 * Non-blocking, returns immediately.
 */
export function preloadPlayerLibs() {
  getHls().catch(() => {});
  getMpegts().catch(() => {});
}
