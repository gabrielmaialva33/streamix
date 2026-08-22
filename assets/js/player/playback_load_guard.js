export async function runGuardedPlaybackRetry({ isCurrent = () => true, onError = () => {}, run }) {
  if (!isCurrent()) return false;

  try {
    await run();
    return isCurrent();
  } catch (error) {
    if (isCurrent()) {
      try {
        onError(error);
      } catch {}
    }
    return false;
  }
}

export function scheduleGuardedPlaybackRetry({
  delayMs = 0,
  isCurrent = () => true,
  onError = () => {},
  run,
  schedule = (callback, delay) => globalThis.setTimeout(callback, delay),
}) {
  return schedule(() => {
    void runGuardedPlaybackRetry({ isCurrent, onError, run });
  }, delayMs);
}

export async function guardPlaybackLoad({
  destroy = () => {},
  isCancelled = () => false,
  isCurrent = () => true,
  load,
}) {
  try {
    const engine = await load();
    if (!isCurrent()) {
      try {
        await destroy(engine);
      } catch {}
      return { engine: null, status: "stale" };
    }

    return { engine, status: "loaded" };
  } catch (error) {
    if (isCancelled(error) || !isCurrent()) {
      return { engine: null, error, status: "cancelled" };
    }

    return { engine: null, error, status: "error" };
  }
}
