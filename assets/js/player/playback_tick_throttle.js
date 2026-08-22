const defaultNow = () => globalThis.performance?.now?.() ?? Date.now();

const nonNegativeInterval = (value, fallback) =>
  Number.isFinite(value) && value >= 0 ? value : fallback;

export function createPlaybackTickThrottle({
  now = defaultNow,
  uiIntervalMs = 125,
  progressIntervalMs = 10_000,
} = {}) {
  const uiInterval = nonNegativeInterval(uiIntervalMs, 125);
  const progressInterval = nonNegativeInterval(progressIntervalMs, 10_000);
  const initialTimestamp = now();
  let lastUiTimestamp = Number.NEGATIVE_INFINITY;
  let lastProgressTimestamp = Number.isFinite(initialTimestamp) ? initialTimestamp : 0;

  return {
    next(timestamp = now()) {
      const currentTimestamp = Number.isFinite(timestamp) ? timestamp : now();
      const clockRestarted =
        currentTimestamp < lastUiTimestamp || currentTimestamp < lastProgressTimestamp;
      const updateUi = clockRestarted || currentTimestamp - lastUiTimestamp >= uiInterval;
      const reportProgress =
        clockRestarted || currentTimestamp - lastProgressTimestamp >= progressInterval;

      if (updateUi) lastUiTimestamp = currentTimestamp;
      if (reportProgress) lastProgressTimestamp = currentTimestamp;

      return { reportProgress, updateUi };
    },
  };
}
