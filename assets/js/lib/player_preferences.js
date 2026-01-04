/**
 * Player Preferences Manager
 *
 * Persists user preferences (volume, mute, audio/subtitle track) to localStorage.
 * Preferences are scoped by content ID when available.
 */

const STORAGE_KEY = 'streamix_player_prefs';
const POSITION_KEY = 'streamix_playback_positions';
const GLOBAL_KEY = 'global';
const MAX_POSITIONS = 100; // Max number of positions to store

/**
 * Get all stored preferences
 */
function getAllPrefs() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? JSON.parse(stored) : {};
  } catch (e) {
    console.warn('[PlayerPreferences] Failed to read preferences:', e);
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
    console.warn('[PlayerPreferences] Failed to save preferences:', e);
  }
}

/**
 * Get preferences for a specific content or global
 */
export function getPreferences(contentId = null) {
  const prefs = getAllPrefs();
  const key = contentId || GLOBAL_KEY;

  // Merge global with content-specific (content-specific takes precedence)
  const globalPrefs = prefs[GLOBAL_KEY] || {};
  const contentPrefs = contentId ? (prefs[contentId] || {}) : {};

  return {
    volume: contentPrefs.volume ?? globalPrefs.volume ?? 1,
    muted: contentPrefs.muted ?? globalPrefs.muted ?? false,
    audioTrack: contentPrefs.audioTrack ?? null,
    subtitleTrack: contentPrefs.subtitleTrack ?? -1,
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
  savePreference('volume', volume, null);
}

/**
 * Save mute preference (always global)
 */
export function saveMuted(muted) {
  savePreference('muted', muted, null);
}

/**
 * Save audio track preference (content-specific if ID provided)
 */
export function saveAudioTrack(trackIndex, contentId = null) {
  savePreference('audioTrack', trackIndex, contentId);
}

/**
 * Save subtitle track preference (content-specific if ID provided)
 */
export function saveSubtitleTrack(trackIndex, contentId = null) {
  savePreference('subtitleTrack', trackIndex, contentId);
}

/**
 * Save playback rate preference (always global)
 */
export function savePlaybackRate(rate) {
  savePreference('playbackRate', rate, null);
}

/**
 * Save AVPlayer preference (manual audio compatibility mode)
 */
export function savePreferAVPlayer(prefer) {
  savePreference('preferAVPlayer', prefer, null);
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
    console.warn('[PlayerPreferences] Failed to clear preferences:', e);
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
    console.warn('[PlayerPreferences] Failed to read positions:', e);
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
    console.warn('[PlayerPreferences] Failed to save positions:', e);
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
    toRemove.forEach(key => delete positions[key]);
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
    console.warn('[PlayerPreferences] Failed to clear positions:', e);
  }
}

export default {
  getPreferences,
  savePreference,
  saveVolume,
  saveMuted,
  saveAudioTrack,
  saveSubtitleTrack,
  savePlaybackRate,
  savePreferAVPlayer,
  clearContentPreferences,
  clearAllPreferences,
  savePlaybackPosition,
  getPlaybackPosition,
  clearPlaybackPosition,
  clearAllPlaybackPositions,
};
