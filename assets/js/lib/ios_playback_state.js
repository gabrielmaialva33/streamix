export const IOS_PLAYER_STATE_KEY = "streamix:ios-player-state";
export const IOS_PLAYER_STATE_MAX_AGE = 12 * 60 * 60 * 1000;

function defaultStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}

export function readIosPlayerState(
  contentId,
  { storage = defaultStorage(), now = Date.now(), maxAge = IOS_PLAYER_STATE_MAX_AGE } = {},
) {
  if (!contentId || !storage) return null;

  try {
    const state = JSON.parse(storage.getItem(IOS_PLAYER_STATE_KEY) || "null");
    if (!state || state.contentId !== contentId || !Number.isFinite(state.savedAt)) return null;
    if (now - state.savedAt > maxAge) return null;
    return state;
  } catch {
    return null;
  }
}

export function writeIosPlayerState(state, { storage = defaultStorage(), now = Date.now() } = {}) {
  if (!state || !storage) return false;

  try {
    storage.setItem(IOS_PLAYER_STATE_KEY, JSON.stringify({ ...state, savedAt: now }));
    return true;
  } catch {
    return false;
  }
}

export function buildIosPlayerState(
  { contentId, path, currentTime, duration, paused, muted, volume, playbackRate },
  extra = {},
) {
  if (!contentId || !Number.isFinite(currentTime) || !Number.isFinite(duration) || duration <= 0) {
    return null;
  }

  return {
    contentId,
    path,
    time: currentTime,
    duration,
    paused,
    userPaused: extra.userPaused ?? paused,
    wasPlaying: extra.wasPlaying ?? !paused,
    muted,
    volume,
    playbackRate,
    reason: extra.reason || "snapshot",
  };
}
