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
      return hook.usingAVPlayer ? "avplayer" : "native";
    },
    getCurrentTime: () => hook.getCurrentTime(),
    getDuration: () => hook.getDuration(),
    isPaused: () => hook.isPaused(),
    seekTo: (time) => hook.seekTo(time),
    play: () => {
      if (hook.isPaused()) hook.togglePlayPause();
    },
    pause: () => {
      if (!hook.isPaused()) hook.togglePlayPause();
    },
    // Playback rate nudging is native-only: AVPlayer has no equivalent
    // knob, so consumers fall back to seeking for those engines.
    setPlaybackRate: (rate) => {
      if (hook.usingAVPlayer) return false;
      hook.setPlaybackRate(rate);
      return true;
    },
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
