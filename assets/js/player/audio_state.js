import { linearToPerceived } from "./volume_utils.js";

const DEFAULT_VOLUME = 1;

function clampVolume(value, fallback = DEFAULT_VOLUME) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return fallback;
  return Math.max(0, Math.min(1, numeric));
}

function normalizeAudioState(state = {}) {
  const volume = clampVolume(state.volume);
  const lastAudibleVolume = clampVolume(state.lastAudibleVolume, DEFAULT_VOLUME) || DEFAULT_VOLUME;

  return {
    volume,
    muted: state.muted === true,
    lastAudibleVolume: volume > 0 ? volume : lastAudibleVolume,
  };
}

/**
 * Builds the canonical audio state from localStorage-compatible preferences.
 * String booleans are accepted because older Streamix releases persisted
 * values coming directly from DOM datasets.
 */
export function hydrateAudioState(preferences = {}) {
  const volume = clampVolume(preferences.volume);

  return {
    volume,
    muted: preferences.muted === true || preferences.muted === "true",
    lastAudibleVolume: volume > 0 ? volume : DEFAULT_VOLUME,
  };
}

/**
 * Applies an absolute UI volume. Raising the slider always makes the active
 * output audible; lowering it to zero preserves the explicit mute flag so the
 * next mute-button press can restore the previous audible value.
 */
export function setAudioVolume(state, requestedVolume) {
  const current = normalizeAudioState(state);
  const volume = clampVolume(requestedVolume);

  return {
    volume,
    muted: volume > 0 ? false : current.muted,
    lastAudibleVolume: volume > 0 ? volume : current.lastAudibleVolume,
  };
}

export function adjustAudioVolume(state, delta) {
  const current = normalizeAudioState(state);
  const numericDelta = Number(delta);
  const safeDelta = Number.isFinite(numericDelta) ? numericDelta : 0;

  return setAudioVolume(current, current.volume + safeDelta);
}

/**
 * Treats both an explicit mute and a zero-volume slider as silent. Unmuting a
 * zero-volume state restores the last audible value instead of leaving the UI
 * "unmuted" while no sound can be produced.
 */
export function toggleAudioMute(state) {
  const current = normalizeAudioState(state);
  const muted = !(current.muted || current.volume === 0);
  const volume = !muted && current.volume === 0 ? current.lastAudibleVolume : current.volume;

  return { ...current, volume, muted };
}

export function audioOutputVolume(state) {
  const current = normalizeAudioState(state);
  return current.muted ? 0 : linearToPerceived(current.volume);
}
