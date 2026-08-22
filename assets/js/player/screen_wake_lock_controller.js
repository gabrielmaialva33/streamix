/**
 * Keeps the display awake while playback is active.
 *
 * Browsers may release a screen wake lock whenever the document becomes
 * hidden. The controller therefore treats visibility as part of its state and
 * reacquires the lock when the page becomes visible again and playback is
 * still active.
 */
export function createScreenWakeLockController({
  navigatorRef = globalThis.navigator,
  documentRef = globalThis.document,
  onError = () => {},
} = {}) {
  let active = false;
  let destroyed = false;
  let sentinel = null;
  let requestPromise = null;

  const isVisible = () => documentRef?.visibilityState !== "hidden";

  const reportError = (operation, error) => {
    try {
      onError(operation, error);
    } catch {
      // Diagnostics must never break playback lifecycle handling.
    }
  };

  const releaseSentinel = async (candidate, operation = "release") => {
    if (!candidate || typeof candidate.release !== "function") return;

    try {
      await candidate.release();
    } catch (error) {
      reportError(operation, error);
    }
  };

  const release = async () => {
    const current = sentinel;
    sentinel = null;
    await releaseSentinel(current);
  };

  const acquire = async () => {
    if (destroyed || !active || !isVisible()) return null;
    if (sentinel && sentinel.released !== true) return sentinel;
    if (requestPromise) return requestPromise;

    const wakeLock = navigatorRef?.wakeLock;
    if (typeof wakeLock?.request !== "function") return null;

    requestPromise = Promise.resolve()
      .then(() => wakeLock.request("screen"))
      .then(async (candidate) => {
        requestPromise = null;
        if (!candidate) return null;

        if (destroyed || !active || !isVisible()) {
          await releaseSentinel(candidate, "release-stale");
          return null;
        }

        sentinel = candidate;
        candidate.addEventListener?.(
          "release",
          () => {
            if (sentinel === candidate) sentinel = null;
          },
          { once: true },
        );

        return candidate;
      })
      .catch((error) => {
        requestPromise = null;
        reportError("request", error);
        return null;
      });

    return requestPromise;
  };

  const sync = () => (active ? acquire() : release());

  const setPlaybackActive = (nextActive) => {
    active = nextActive === true;
    return sync();
  };

  const handleVisibilityChange = () => {
    if (isVisible()) {
      if (active) void acquire();
    } else {
      void release();
    }
  };

  documentRef?.addEventListener?.("visibilitychange", handleVisibilityChange);

  return {
    acquire,
    release,
    setPlaybackActive,
    // Backward-compatible alias for callers outside the player hook.
    setActive: setPlaybackActive,
    sync,
    get active() {
      return active;
    },
    get held() {
      return Boolean(sentinel && sentinel.released !== true);
    },
    async destroy() {
      if (destroyed) return;
      destroyed = true;
      active = false;
      documentRef?.removeEventListener?.("visibilitychange", handleVisibilityChange);
      await release();
    },
  };
}
