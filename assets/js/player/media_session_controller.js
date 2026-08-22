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
} = {}) {
  const mediaSession = navigatorRef?.mediaSession;
  let destroyed = false;

  const reportError = (error) => {
    try {
      onError(error);
    } catch {
      // Media integration is best-effort and must never interrupt playback.
    }
  };

  const safely = (operation) => {
    if (!mediaSession || destroyed) return false;

    try {
      operation();
      return true;
    } catch (error) {
      reportError(error);
      return false;
    }
  };

  const setup = () => {
    if (!mediaSession || destroyed) return false;

    safely(() => {
      const MediaMetadataImpl = windowRef?.MediaMetadata;
      if (typeof MediaMetadataImpl === "function") {
        mediaSession.metadata = new MediaMetadataImpl(metadata);
      }
    });

    for (const action of MEDIA_ACTIONS) {
      const handler = actions[action];
      if (typeof handler !== "function") continue;
      safely(() => mediaSession.setActionHandler(action, handler));
    }

    return true;
  };

  const setPlaybackState = (state) => {
    const normalizedState = PLAYBACK_STATES.has(state) ? state : "none";
    return safely(() => {
      mediaSession.playbackState = normalizedState;
    });
  };

  const clearPositionState = () =>
    safely(() => {
      if (typeof mediaSession.setPositionState === "function") {
        mediaSession.setPositionState();
      }
    });

  const setPositionState = (state) => {
    const normalizedState = normalizeMediaPositionState(state);
    if (!normalizedState) return false;

    return safely(() => {
      if (typeof mediaSession.setPositionState === "function") {
        mediaSession.setPositionState(normalizedState);
      }
    });
  };

  return {
    setup,
    setPlaybackState,
    setPositionState,
    clearPositionState,
    get supported() {
      return Boolean(mediaSession);
    },
    destroy() {
      if (destroyed) return;

      if (mediaSession) {
        for (const action of MEDIA_ACTIONS) {
          safely(() => mediaSession.setActionHandler(action, null));
        }
        clearPositionState();
        setPlaybackState("none");
        safely(() => {
          mediaSession.metadata = null;
        });
      }

      destroyed = true;
    },
  };
}
