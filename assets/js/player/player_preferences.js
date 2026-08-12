/**
 * Player Preferences Manager
 *
 * Persists user preferences (volume, mute, audio/subtitle track) to localStorage.
 * Preferences are scoped by content ID when available.
 */

import { prefsLogger as log } from "../core/logger.js";

const STORAGE_KEY = "streamix_player_prefs";
const POSITION_KEY = "streamix_playback_positions";
const DEVICE_COMPAT_KEY = "streamix_device_compat";
const GLOBAL_KEY = "global";
const MAX_POSITIONS = 100; // Max number of positions to store

// Schema version for `streamix_device_compat`. Bump when an engine
// decision learned by an older version of the app becomes invalid (e.g.
// the proxy backend changes and the previously-recommended player no
// longer applies). Reads with a stale schema are wiped on the next
// access — much cheaper than asking every user to clear localStorage by
// hand.
// Bumped to 3 (2026-05-24): a deploy broke AVPlayer for MP4/xtream and
// users who'd previously recorded 30+ AVPlayer successes were stuck on
// `open stream failed, ret: -2` because the cached recommendation kept
// short-circuiting the native engine. Schema bump wipes every client's
// memory on next load so engine_selector re-evaluates from scratch.
const DEVICE_COMPAT_SCHEMA = 3;

// ============================================
// Device Fingerprint & Codec Compatibility
// ============================================

/**
 * Generate a simple device fingerprint for codec compatibility tracking
 * This helps remember which player/codec works on this specific device
 */
function getDeviceFingerprint() {
  const canvas = document.createElement("canvas");
  const gl = canvas.getContext("webgl");
  const renderer = gl ? gl.getParameter(gl.UNMASKED_RENDERER_WEBGL) : "unknown";

  return {
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    gpu: renderer,
    screen: `${screen.width}x${screen.height}`,
    memory: navigator.deviceMemory || "unknown",
    cores: navigator.hardwareConcurrency || "unknown",
  };
}

/**
 * Get stored device compatibility data
 */
function getDeviceCompatibility() {
  const empty = { schema: DEVICE_COMPAT_SCHEMA, codecs: {}, players: {}, lastUpdated: null };

  try {
    const stored = localStorage.getItem(DEVICE_COMPAT_KEY);
    if (!stored) return empty;

    const parsed = JSON.parse(stored);

    // Wipe on stale schema — a player previously learned by the user
    // may no longer be the right call (e.g. backend changed from
    // Tuliprox-style 302 to BEAM-side proxy and AVPlayer no longer
    // loads via Range requests). Returning `empty` causes
    // `getRecommendedPlayer/1` to fall back to engine_selector's
    // pure rules.
    if (parsed.schema !== DEVICE_COMPAT_SCHEMA) {
      log.debug(`device-compat schema bumped (${parsed.schema} → ${DEVICE_COMPAT_SCHEMA}); wiping`);
      localStorage.removeItem(DEVICE_COMPAT_KEY);
      return empty;
    }

    return parsed;
  } catch (e) {
    log.warn("Failed to read device compatibility:", e);
    return empty;
  }
}

/**
 * Save device compatibility data
 */
function saveDeviceCompatibility(compat) {
  try {
    compat.schema = DEVICE_COMPAT_SCHEMA;
    compat.lastUpdated = Date.now();
    localStorage.setItem(DEVICE_COMPAT_KEY, JSON.stringify(compat));
  } catch (e) {
    log.warn("Failed to save device compatibility:", e);
  }
}

/**
 * Forget the recommended player for a content type. Called when the
 * cached recommendation has just failed (timeout, decode error) so the
 * next playback attempt falls back to engine_selector defaults.
 */
export function forgetRecommendedPlayer(contentType) {
  const compat = getDeviceCompatibility();
  if (compat.players[contentType]) {
    delete compat.players[contentType];
    saveDeviceCompatibility(compat);
    log.debug(`Forgot recommended player for ${contentType}`);
  }
}

/**
 * Record which player worked for a specific content type
 * @param {string} contentType - Content type (e.g., 'mkv', 'gindex', 'hls')
 * @param {string} player - Player that worked ('native', 'avplayer', 'hls', 'mpegts')
 * @param {object} context - Additional context (codecs detected, etc.)
 */
export function recordPlayerSuccess(contentType, player, context = {}) {
  const compat = getDeviceCompatibility();

  compat.players[contentType] = {
    recommendedPlayer: player,
    context,
    successCount: (compat.players[contentType]?.successCount || 0) + 1,
    lastSuccess: Date.now(),
  };

  saveDeviceCompatibility(compat);
  log.debug(`Recorded player success: ${contentType} -> ${player}`);
}

/**
 * Get recommended player for a content type based on past experience
 * @param {string} contentType - Content type to check
 * @returns {string|null} Recommended player or null if no data
 */
export function getRecommendedPlayer(contentType) {
  const compat = getDeviceCompatibility();
  const playerData = compat.players[contentType];

  if (!playerData) return null;

  // Only trust recommendations from the last 30 days
  const thirtyDays = 30 * 24 * 60 * 60 * 1000;
  if (Date.now() - playerData.lastSuccess > thirtyDays) {
    return null;
  }

  // Require at least 2 successful plays to trust the recommendation
  if (playerData.successCount >= 2) {
    return playerData.recommendedPlayer;
  }

  return null;
}

/**
 * Get full device compatibility report
 * Useful for diagnostics and debugging
 */
export function getDeviceCompatibilityReport() {
  const compat = getDeviceCompatibility();
  const fingerprint = getDeviceFingerprint();

  return {
    device: fingerprint,
    codecs: compat.codecs,
    players: compat.players,
    lastUpdated: compat.lastUpdated,
  };
}

/**
 * Get all stored preferences
 */
function getAllPrefs() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? JSON.parse(stored) : {};
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to read preferences:", e);
    return {};
  }
}

/**
 * Save all preferences
 */
function saveAllPrefs(prefs) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to save preferences:", e);
  }
}

/**
 * Get preferences for a specific content or global
 */
export function getPreferences(contentId = null) {
  const prefs = getAllPrefs();
  const _key = contentId || GLOBAL_KEY;

  // Merge global with content-specific (content-specific takes precedence)
  const globalPrefs = prefs[GLOBAL_KEY] || {};
  const contentPrefs = contentId ? prefs[contentId] || {} : {};

  return {
    volume: contentPrefs.volume ?? globalPrefs.volume ?? 1,
    muted: contentPrefs.muted ?? globalPrefs.muted ?? false,
    audioTrack: contentPrefs.audioTrack ?? null,
    subtitleTrack: contentPrefs.subtitleTrack ?? globalPrefs.subtitleTrack ?? null,
    playbackRate: globalPrefs.playbackRate ?? 1,
    preferAVPlayer: globalPrefs.preferAVPlayer ?? false, // Manual audio compatibility mode
  };
}

/**
 * Save a specific preference
 */
export function savePreference(key, value, contentId = null) {
  const prefs = getAllPrefs();
  const prefKey = contentId || GLOBAL_KEY;

  if (!prefs[prefKey]) {
    prefs[prefKey] = {};
  }

  prefs[prefKey][key] = value;
  saveAllPrefs(prefs);
}

/**
 * Save volume preference (always global)
 */
export function saveVolume(volume) {
  savePreference("volume", volume, null);
}

/**
 * Save mute preference (always global)
 */
export function saveMuted(muted) {
  savePreference("muted", muted, null);
}

/**
 * Save audio track preference (content-specific if ID provided)
 */
export function saveAudioTrack(trackIndex, contentId = null) {
  savePreference("audioTrack", trackIndex, contentId);
}

/**
 * Save subtitle track preference (content-specific if ID provided)
 */
export function saveSubtitleTrack(trackIndex, contentId = null) {
  savePreference("subtitleTrack", trackIndex, contentId);
}

/**
 * Save playback rate preference (always global)
 */
export function savePlaybackRate(rate) {
  savePreference("playbackRate", rate, null);
}

/**
 * Save AVPlayer preference (manual audio compatibility mode)
 */
export function savePreferAVPlayer(prefer) {
  savePreference("preferAVPlayer", prefer, null);
}

/**
 * Clear preferences for a specific content
 */
export function clearContentPreferences(contentId) {
  if (!contentId) return;

  const prefs = getAllPrefs();
  delete prefs[contentId];
  saveAllPrefs(prefs);
}

/**
 * Clear all preferences
 */
export function clearAllPreferences() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to clear preferences:", e);
  }
}

// ============================================
// VOD Playback Position Memory
// ============================================

/**
 * Get all stored playback positions
 */
function getAllPositions() {
  try {
    const stored = localStorage.getItem(POSITION_KEY);
    return stored ? JSON.parse(stored) : {};
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to read positions:", e);
    return {};
  }
}

/**
 * Save all playback positions
 */
function saveAllPositions(positions) {
  try {
    localStorage.setItem(POSITION_KEY, JSON.stringify(positions));
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to save positions:", e);
  }
}

/**
 * Save playback position for VOD content
 * @param {string} contentId - Content identifier
 * @param {number} currentTime - Current playback position in seconds
 * @param {number} duration - Total duration in seconds
 */
export function savePlaybackPosition(contentId, currentTime, duration) {
  if (!contentId || !currentTime || !duration) return;

  // Don't save if at the beginning or near the end (within 30s or 95%)
  if (currentTime < 10 || currentTime > duration - 30 || currentTime / duration > 0.95) {
    // Clear position if near the end (content was finished)
    if (currentTime / duration > 0.95) {
      clearPlaybackPosition(contentId);
    }
    return;
  }

  const positions = getAllPositions();

  // Add timestamp for LRU eviction
  positions[contentId] = {
    time: currentTime,
    duration: duration,
    timestamp: Date.now(),
  };

  // Evict oldest positions if over limit
  const keys = Object.keys(positions);
  if (keys.length > MAX_POSITIONS) {
    const sortedKeys = keys.sort((a, b) => positions[a].timestamp - positions[b].timestamp);
    const toRemove = sortedKeys.slice(0, keys.length - MAX_POSITIONS);
    for (const key of toRemove) {
      delete positions[key];
    }
  }

  saveAllPositions(positions);
}

/**
 * Get saved playback position for VOD content
 * @param {string} contentId - Content identifier
 * @returns {{time: number, duration: number} | null} - Saved position or null
 */
export function getPlaybackPosition(contentId) {
  if (!contentId) return null;

  const positions = getAllPositions();
  const position = positions[contentId];

  if (!position) return null;

  return {
    time: position.time,
    duration: position.duration,
  };
}

/**
 * Clear playback position for specific content
 */
export function clearPlaybackPosition(contentId) {
  if (!contentId) return;

  const positions = getAllPositions();
  delete positions[contentId];
  saveAllPositions(positions);
}

/**
 * Clear all playback positions
 */
export function clearAllPlaybackPositions() {
  try {
    localStorage.removeItem(POSITION_KEY);
  } catch (e) {
    console.warn("[PlayerPreferences] Failed to clear positions:", e);
  }
}
