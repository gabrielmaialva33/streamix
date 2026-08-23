export const IOS_PLAYER_STATE_KEY = "streamix:ios-player-state";
export const IOS_PLAYER_STATE_MAX_AGE = 12 * 60 * 60 * 1000;

const MAX_FUTURE_CLOCK_SKEW_MS = 5 * 60 * 1000;
const MIN_PLAYBACK_RATE = 0.25;
const MAX_PLAYBACK_RATE = 2;
const MAX_CONTENT_ID_LENGTH = 128;
const MAX_PATH_LENGTH = 2048;
const MAX_REASON_LENGTH = 64;

function defaultStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function normalizeText(value, maximumLength, fallback = "") {
  if (typeof value !== "string") return fallback;
  return value.slice(0, maximumLength);
}

function normalizeContentId(value) {
  if (typeof value !== "string" && typeof value !== "number") return null;

  const contentId = String(value).trim();
  return contentId.length > 0 && contentId.length <= MAX_CONTENT_ID_LENGTH ? contentId : null;
}

function normalizePlaybackRate(value) {
  const rate = finiteNumber(value);
  return rate === null ? 1 : clamp(rate, MIN_PLAYBACK_RATE, MAX_PLAYBACK_RATE);
}

function normalizeVolume(value) {
  const volume = finiteNumber(value);
  return volume === null ? 1 : clamp(volume, 0, 1);
}

export function buildIosPlayerState(
  { contentId, path, currentTime, duration, paused, muted, volume, playbackRate },
  extra = {},
) {
  const normalizedContentId = normalizeContentId(contentId);
  const normalizedDuration = finiteNumber(duration);
  const normalizedTime = finiteNumber(currentTime);

  if (
    !normalizedContentId ||
    normalizedTime === null ||
    normalizedDuration === null ||
    normalizedDuration <= 0
  ) {
    return null;
  }

  const pausedState = paused === true;

  return {
    contentId: normalizedContentId,
    path: normalizeText(path, MAX_PATH_LENGTH),
    time: clamp(normalizedTime, 0, normalizedDuration),
    duration: normalizedDuration,
    paused: pausedState,
    userPaused: typeof extra.userPaused === "boolean" ? extra.userPaused : pausedState,
    wasPlaying: typeof extra.wasPlaying === "boolean" ? extra.wasPlaying : !pausedState,
    muted: muted === true,
    volume: normalizeVolume(volume),
    playbackRate: normalizePlaybackRate(playbackRate),
    reason: normalizeText(extra.reason, MAX_REASON_LENGTH, "snapshot") || "snapshot",
  };
}

function normalizeStoredState(state) {
  if (!state || typeof state !== "object") return null;

  return buildIosPlayerState(
    {
      contentId: state.contentId,
      path: state.path,
      currentTime: state.time,
      duration: state.duration,
      paused: state.paused,
      muted: state.muted,
      volume: state.volume,
      playbackRate: state.playbackRate,
    },
    {
      reason: state.reason,
      userPaused: state.userPaused,
      wasPlaying: state.wasPlaying,
    },
  );
}

export function readIosPlayerState(
  contentId,
  { storage = defaultStorage(), now = Date.now(), maxAge = IOS_PLAYER_STATE_MAX_AGE } = {},
) {
  const normalizedContentId = normalizeContentId(contentId);
  if (!normalizedContentId || !storage) return null;

  try {
    const state = JSON.parse(storage.getItem(IOS_PLAYER_STATE_KEY) || "null");
    const savedAt = finiteNumber(state?.savedAt);
    const normalizedNow = finiteNumber(now);
    const normalizedMaxAge = finiteNumber(maxAge);

    if (
      !state ||
      normalizeContentId(state.contentId) !== normalizedContentId ||
      savedAt === null ||
      normalizedNow === null ||
      normalizedMaxAge === null ||
      normalizedMaxAge < 0 ||
      savedAt > normalizedNow + MAX_FUTURE_CLOCK_SKEW_MS ||
      normalizedNow - savedAt > normalizedMaxAge
    ) {
      return null;
    }

    const normalizedState = normalizeStoredState(state);
    return normalizedState ? { ...normalizedState, savedAt } : null;
  } catch {
    return null;
  }
}

export function writeIosPlayerState(state, { storage = defaultStorage(), now = Date.now() } = {}) {
  if (!state || !storage) return false;

  const savedAt = finiteNumber(now);
  const normalizedState = normalizeStoredState(state);
  if (savedAt === null || !normalizedState) return false;

  try {
    storage.setItem(IOS_PLAYER_STATE_KEY, JSON.stringify({ ...normalizedState, savedAt }));
    return true;
  } catch {
    return false;
  }
}
