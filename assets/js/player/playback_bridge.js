/**
 * Playback bridge — engine-agnostic remote control for the active player.
 *
 * The VideoPlayer hook owns playback, but it can be driving either the
 * native `<video>` element or an AVPlayer (libmedia) canvas. Anything
 * outside the hook that needs to observe or steer playback — watch party
 * sync being the only consumer today — used to reach for
 * `document.querySelector("video")`, which is silently wrong whenever
 * AVPlayer is the active engine: that element stays paused at 0s while
 * the real playback happens on a canvas.
 *
 * The bridge exposes the hook's already engine-agnostic accessors on the
 * player container element, plus DOM events for state changes, so
 * consumers never have to know which engine is running.
 */

export const PLAYBACK_BRIDGE_EVENT = "streamix:playback";

/**
 * Publishes the bridge on `el` and returns a disposer.
 *
 * @param {HTMLElement} el player container (the VideoPlayer hook element)
 * @param {object} hook the VideoPlayer hook instance
 */
export function installPlaybackBridge(el, hook) {
  if (!el || !hook) return () => {};

  el.streamixPlayback = {
    get engine() {
      if (hook.usingAVPlayer) return "avplayer";
      if (hook.usingH265web) return "h265web";
      if (hook.usingAvbridge) return "avbridge";
      return "native";
    },
    getCurrentTime: () => hook.getCurrentTime(),
    getDuration: () => hook.getDuration(),
    isPaused: () => hook.isPaused(),
    getPlaybackRate: () => hook.getPlaybackRate?.() || 1,
    supportsPlaybackRate: () => hook.supportsPlaybackRateControl?.() !== false,
    seekTo: (time) => hook.seekTo(time, { remote: true }),
    play: () => {
      if (hook.isPaused()) return hook.togglePlayPause({ remote: true });
      return true;
    },
    pause: () => {
      if (!hook.isPaused()) return hook.togglePlayPause({ remote: true });
      return true;
    },
    // Canvas engines expose no reliable rate control, so consumers fall
    // back to seeking instead of pretending a hidden <video> changed speed.
    setPlaybackRate: (rate) => hook.setPlaybackRate(rate, { remote: true }) !== false,
    setSyncHold: (held) =>
      typeof hook.setWatchPartySyncHold === "function"
        ? hook.setWatchPartySyncHold(held)
        : undefined,
  };

  return () => {
    if (el.streamixPlayback) delete el.streamixPlayback;
  };
}

/**
 * Emits a playback state change so listeners can react without polling.
 *
 * @param {HTMLElement} el player container
 * @param {"play"|"pause"|"seeked"} type
 */
export function emitPlaybackEvent(el, type) {
  if (!el) return;

  el.dispatchEvent(
    new CustomEvent(PLAYBACK_BRIDGE_EVENT, {
      bubbles: true,
      detail: {
        type,
        position: el.streamixPlayback ? el.streamixPlayback.getCurrentTime() : 0,
      },
    }),
  );
}

/**
 * Finds the bridge for the player currently on the page.
 *
 * @returns {object|null}
 */
export function findPlaybackBridge() {
  const el = document.getElementById("video-player-container");
  return el?.streamixPlayback || null;
}
