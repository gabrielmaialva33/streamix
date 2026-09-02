export const DRIFT_ACTION = Object.freeze({
  HOLD: "hold",
  NUDGE: "nudge",
  PAUSE: "pause",
  RESUME: "resume",
  SEEK: "seek",
  SYNCED: "synced",
});

export const MAX_EXTRAPOLATION_SECONDS = 10;
export const RATE_RESET_DELAY_MS = 3_000;

export function driftThresholds(conservative) {
  return conservative
    ? Object.freeze({ play: 1.0, synced: 1.0, seek: 3.0 })
    : Object.freeze({ play: 0.3, synced: 0.1, seek: 0.5 });
}

export function playbackRateForDrift(drift) {
  const direction = drift < 0 ? 1 : -1;
  const normalized = Math.min(1, Math.abs(drift) / 0.5);
  const adjustment = normalized * normalized * 0.15;
  return Math.max(0.8, Math.min(1.2, 1 + direction * adjustment));
}

/**
 * Pure drift policy for a viewer following the host.
 *
 * Returns `null` for invalid input, otherwise one action describing how the
 * viewer must react: resume, pause, seek, nudge the playback rate, hold
 * (conservative engines) or stay synced. Applying the action is the hook's
 * job; this keeps the thresholds and the rate curve testable in isolation.
 */
export function resolveDriftCorrection({
  clockReady = false,
  conservative = false,
  currentPosition,
  paused,
  serverNow = null,
  serverPosition,
  serverState,
  serverTime,
} = {}) {
  const position = Number(serverPosition);
  const sentAt = Number(serverTime);
  if (!Number.isFinite(position) || position < 0) return null;
  if (!["playing", "paused"].includes(serverState)) return null;

  const elapsed =
    serverState === "playing" && clockReady && Number.isFinite(sentAt) && Number.isFinite(serverNow)
      ? Math.max(0, Math.min(MAX_EXTRAPOLATION_SECONDS, (serverNow - sentAt) / 1000))
      : 0;
  const targetPosition = position + elapsed;
  const drift = Number(currentPosition) - targetPosition;
  const absoluteDrift = Math.abs(drift);
  const driftMs = Math.round(absoluteDrift * 1000);
  const thresholds = driftThresholds(conservative);
  const base = { drift, driftMs, targetPosition };

  if (serverState === "playing" && paused) {
    return Object.freeze({
      ...base,
      action: DRIFT_ACTION.RESUME,
      beacon: "catchup",
      lock: true,
      seek: absoluteDrift > thresholds.play,
      status: "correcting",
    });
  }

  if (serverState === "paused" && !paused) {
    return Object.freeze({
      ...base,
      action: DRIFT_ACTION.PAUSE,
      beacon: "synced",
      lock: true,
      seek: true,
      status: "synced",
    });
  }

  if (absoluteDrift < thresholds.synced) {
    return Object.freeze({
      ...base,
      action: DRIFT_ACTION.SYNCED,
      beacon: "synced",
      lock: false,
      seek: false,
      status: "synced",
    });
  }

  if (absoluteDrift > thresholds.seek) {
    return Object.freeze({
      ...base,
      action: DRIFT_ACTION.SEEK,
      beacon: "catchup",
      lock: true,
      seek: true,
      status: "correcting",
    });
  }

  if (conservative) {
    return Object.freeze({
      ...base,
      action: DRIFT_ACTION.HOLD,
      beacon: "synced",
      lock: false,
      seek: false,
      status: "synced",
    });
  }

  return Object.freeze({
    ...base,
    action: DRIFT_ACTION.NUDGE,
    beacon: "correcting",
    lock: false,
    rate: playbackRateForDrift(drift),
    seek: false,
    status: "correcting",
  });
}
