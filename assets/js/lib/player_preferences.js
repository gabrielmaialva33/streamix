/**
 * Player Preferences Manager
 *
 * Persists user preferences (volume, mute, audio/subtitle track) to localStorage.
 * Preferences are scoped by content ID when available.
 */

const STORAGE_KEY = 'streamix_player_prefs';
const GLOBAL_KEY = 'global';

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
};
