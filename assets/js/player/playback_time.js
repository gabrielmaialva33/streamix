export function clampSeekTime(time, duration) {
  if (!Number.isFinite(time) || !Number.isFinite(duration) || duration <= 0) {
    return null;
  }

  return Math.max(0, Math.min(duration, time));
}

export function relativeSeekTarget(currentTime, delta, duration) {
  if (!Number.isFinite(currentTime) || !Number.isFinite(delta)) return null;

  return clampSeekTime(currentTime + delta, duration);
}
