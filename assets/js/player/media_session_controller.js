const MEDIA_ACTIONS = ["play", "pause", "seekbackward", "seekforward", "seekto"];
const PLAYBACK_STATES = new Set(["none", "paused", "playing"]);

export function normalizeMediaPositionState({ duration, position, playbackRate = 1 } = {}) {
  const normalizedDuration = Number(duration);
  const normalizedPosition = Number(position);
  const normalizedRate = Number(playbackRate);

  if (!Number.isFinite(normalizedDuration) || normalizedDuration <= 0) return null;
  if (!Number.isFinite(normalizedPosition)) return null;

  return {
    duration: normalizedDuration,
    position: Math.min(normalizedDuration, Math.max(0, normalizedPosition)),
    playbackRate: Number.isFinite(normalizedRate) && normalizedRate > 0 ? normalizedRate : 1,
  };
}

/**
 * Small adapter around the Media Session API. It deliberately accepts
 * explicit playback states so canvas/WASM engines are not inferred from the
 * permanently-paused native <video> element.
 */
export function createMediaSessionController({
  navigatorRef = globalThis.navigator,
  windowRef = globalThis.window,
  metadata = {},
  actions = {},
  onError = () => {},
  now = () => Date.now(),
  positionUpdateIntervalMs = 1_000,
} = {}) {
  const mediaSession = navigatorRef?.mediaSession;
  let destroyed = false;
  let lastPositionUpdateAt = Number.NEGATIVE_INFINITY;

  const reportError = (operation, error) => {
    try {
      onError(operation, error);
    } catch {
      // Media integration is best-effort and must never interrupt playback.
    }
  };

  const safely = (operation, callback) => {
    if (!mediaSession || destroyed) return false;

    try {
      callback();
      return true;
    } catch (error) {
      reportError(operation, error);
      return false;
    }
  };

  const setup = () => {
    if (!mediaSession || destroyed) return false;

    safely("metadata", () => {
      const MediaMetadataImpl = windowRef?.MediaMetadata;
      if (typeof MediaMetadataImpl === "function") {
        mediaSession.metadata = new MediaMetadataImpl(metadata);
      }
    });

    for (const action of MEDIA_ACTIONS) {
      const handler = actions[action];
      if (typeof handler !== "function") continue;
      safely(`action:${action}`, () => mediaSession.setActionHandler(action, handler));
    }

    return true;
  };

  const setPlaybackState = (state) => {
    const normalizedState = PLAYBACK_STATES.has(state) ? state : "none";
    return safely("playback-state", () => {
      mediaSession.playbackState = normalizedState;
    });
  };

  const clearPositionState = () => {
    const cleared = safely("position:clear", () => {
      if (typeof mediaSession.setPositionState === "function") {
        mediaSession.setPositionState();
      }
    });

    if (cleared) lastPositionUpdateAt = Number.NEGATIVE_INFINITY;
    return cleared;
  };

  const publishPosition = (normalizedState) =>
    safely("position:update", () => {
      if (typeof mediaSession.setPositionState === "function") {
        mediaSession.setPositionState(normalizedState);
      }
    });

  const setPositionState = (state) => {
    const normalizedState = normalizeMediaPositionState(state);
    if (!normalizedState) return false;

    const updated = publishPosition(normalizedState);
    if (updated) lastPositionUpdateAt = now();
    return updated;
  };

  const updatePosition = ({ force = false, ...state } = {}) => {
    const normalizedState = normalizeMediaPositionState(state);
    if (!normalizedState) return false;

    const timestamp = now();
    if (!force && timestamp - lastPositionUpdateAt < positionUpdateIntervalMs) return false;

    const updated = publishPosition(normalizedState);
    if (updated) lastPositionUpdateAt = timestamp;
    return updated;
  };

  return {
    setup,
    setPlaybackState,
    setPositionState,
    updatePosition,
    clearPositionState,
    clearPosition: clearPositionState,
    get supported() {
      return Boolean(mediaSession);
    },
    destroy() {
      if (destroyed) return;

      if (mediaSession) {
        for (const action of MEDIA_ACTIONS) {
          safely(`action:${action}:destroy`, () => mediaSession.setActionHandler(action, null));
        }
        clearPositionState();
        setPlaybackState("none");
        safely("metadata:destroy", () => {
          mediaSession.metadata = null;
        });
      }

      destroyed = true;
    },
  };
}
