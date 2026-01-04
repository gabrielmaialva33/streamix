/**
 * Volume Utilities
 *
 * Provides logarithmic volume scaling for consistent perceived loudness
 * across different audio backends.
 *
 * Human perception of sound follows a logarithmic scale, so a linear
 * volume slider will feel like most of the useful range is in the last 20%.
 * By applying a curve, we make 50% on the slider feel like 50% loudness.
 */

/**
 * Convert linear volume (0-1) to perceived volume (logarithmic)
 * This is used when setting volume on the audio backend
 *
 * @param {number} linear - Linear volume 0-1 (from UI slider)
 * @returns {number} Perceived volume 0-1 (for audio backend)
 */
export function linearToPerceived(linear) {
  if (linear <= 0) return 0;
  if (linear >= 1) return 1;

  // Use a quadratic curve for smoother transition
  // This makes the slider feel more natural
  return linear * linear;
}

/**
 * Convert perceived volume (0-1) to linear volume
 * This is used when reading volume from the audio backend
 *
 * @param {number} perceived - Perceived volume 0-1 (from audio backend)
 * @returns {number} Linear volume 0-1 (for UI slider)
 */
export function perceivedToLinear(perceived) {
  if (perceived <= 0) return 0;
  if (perceived >= 1) return 1;

  // Inverse of the quadratic curve
  return Math.sqrt(perceived);
}

/**
 * Normalize volume for a specific audio backend
 *
 * @param {number} uiVolume - Volume from UI slider (0-1)
 * @param {'native'|'avplayer'} backend - Audio backend type
 * @returns {number} Normalized volume for the backend (0-1)
 */
export function normalizeVolumeForBackend(uiVolume, backend) {
  // Both native HTML5 audio and AVPlayer use linear volume internally
  // We apply the same curve to both for consistency
  return linearToPerceived(uiVolume);
}

/**
 * Get UI volume from a backend's volume level
 *
 * @param {number} backendVolume - Volume from backend (0-1)
 * @param {'native'|'avplayer'} backend - Audio backend type
 * @returns {number} Volume for UI slider (0-1)
 */
export function getUIVolumeFromBackend(backendVolume, backend) {
  // Convert back to linear for UI display
  return perceivedToLinear(backendVolume);
}

export default {
  linearToPerceived,
  perceivedToLinear,
  normalizeVolumeForBackend,
  getUIVolumeFromBackend,
};
