import {
  buildIosPlayerState,
  readIosPlayerState,
  writeIosPlayerState,
} from "./ios_playback_state.js";

const noop = () => {};

const defaultPath = () => {
  const location = globalThis.location;
  if (!location) return "";
  return `${location.pathname || ""}${location.search || ""}`;
};

const defaultVisibilityState = () => globalThis.document?.visibilityState || "visible";

const finiteNumber = (value, fallback = 0) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
};

/**
 * Owns the iOS standalone-PWA playback lifecycle independently from the
 * LiveView hook. All media state is supplied through getters so source
 * failover and engine switches cannot leave this controller with stale data.
 */
export function createIosPwaPlaybackController({
  isEnabled = () => false,
  getContentType = () => null,
  getContentId = () => null,
  getVideo = () => null,
  getPath = defaultPath,
  getVisibilityState = defaultVisibilityState,
  getCurrentTime = () => 0,
  getDuration = () => 0,
  isPaused = () => true,
  getAudioState = () => ({ muted: false, volume: 1 }),
  setAudioState = noop,
  applyAudioState = noop,
  savePlaybackPosition = noop,
  buildState = buildIosPlayerState,
  readState = readIosPlayerState,
  writeState = writeIosPlayerState,
  onStorageUnavailable = noop,
  onSeekError = noop,
  onPlayError = noop,
} = {}) {
  let suspending = false;
  let wasPlayingBeforeHidden = false;

  const supportsPersistence = () => isEnabled() && getContentType() === "vod";

  const persist = (extra = {}) => {
    const contentId = getContentId();
    if (!supportsPersistence() || !contentId) return false;

    const currentTime = Math.floor(finiteNumber(getCurrentTime()));
    const duration = Math.floor(finiteNumber(getDuration()));
    const audioState = getAudioState() || {};
    const video = getVideo();

    const state = buildState(
      {
        contentId,
        path: getPath(),
        currentTime,
        duration,
        paused: Boolean(isPaused()),
        muted: Boolean(audioState.muted),
        volume: finiteNumber(audioState.volume, 1),
        playbackRate: finiteNumber(video?.playbackRate, 1),
      },
      extra,
    );

    if (!state) return false;

    if (currentTime > 0) {
      savePlaybackPosition(contentId, currentTime, duration);
    }

    const written = writeState(state);
    if (!written) onStorageUnavailable();
    return written;
  };

  const pauseWasUserInitiated = () => !suspending && getVisibilityState() !== "hidden";

  const resume = () => {
    const video = getVideo();
    const contentId = getContentId();
    if (!supportsPersistence() || !contentId || !video) return null;

    const state = readState(contentId);
    if (!state) return null;

    const currentAudioState = getAudioState() || {};
    setAudioState({
      volume: Number.isFinite(state.volume)
        ? state.volume
        : finiteNumber(currentAudioState.volume, 1),
      muted: typeof state.muted === "boolean" ? state.muted : Boolean(currentAudioState.muted),
    });
    applyAudioState();

    if (Number.isFinite(state.playbackRate) && state.playbackRate > 0) {
      video.playbackRate = state.playbackRate;
    }

    if (
      Number.isFinite(state.time) &&
      state.time > 5 &&
      Math.abs(finiteNumber(video.currentTime) - state.time) > 2
    ) {
      try {
        video.currentTime = state.time;
      } catch (error) {
        onSeekError(error);
      }
    }

    const shouldResume = Boolean(state.wasPlaying || wasPlayingBeforeHidden);
    wasPlayingBeforeHidden = false;

    if (state.userPaused) {
      video.pause();
      return null;
    }

    if (!shouldResume) return null;

    try {
      return Promise.resolve(video.play()).catch((error) => {
        if (error?.name !== "AbortError" && error?.name !== "NotAllowedError") {
          onPlayError(error);
        }
      });
    } catch (error) {
      if (error?.name !== "AbortError" && error?.name !== "NotAllowedError") {
        onPlayError(error);
      }
      return null;
    }
  };

  const handleVisibilityChange = () => {
    if (!supportsPersistence()) return null;

    if (getVisibilityState() === "hidden") {
      const wasPlaying = !isPaused();
      suspending = true;
      wasPlayingBeforeHidden = wasPlaying;
      persist({ userPaused: false, wasPlaying, reason: "hidden" });
      return null;
    }

    suspending = false;
    return resume();
  };

  const handlePageHide = (event) => {
    if (!supportsPersistence()) return false;

    const wasPlaying = !isPaused();
    suspending = true;
    wasPlayingBeforeHidden = wasPlaying;

    return persist({
      userPaused: false,
      wasPlaying,
      reason: event?.persisted ? "pagehide-persisted" : "pagehide",
    });
  };

  return {
    handlePageHide,
    handleVisibilityChange,
    pauseWasUserInitiated,
    persist,
    resume,
  };
}
