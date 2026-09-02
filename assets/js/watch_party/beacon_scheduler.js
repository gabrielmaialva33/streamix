export const BEACON_INTERVALS_MS = Object.freeze({
  catchup: 1_000,
  correcting: 2_000,
  normal: 5_000,
  synced: 8_000,
});

export const DEFAULT_BEACON_INTERVAL_MS = BEACON_INTERVALS_MS.normal;

function requiredFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`BeaconScheduler requires ${name}()`);
  }
  return value;
}

/**
 * Periodic position beacons with an interval that adapts to how far the
 * viewer is from the host: tight while catching up, relaxed once synced.
 */
export class BeaconScheduler {
  constructor({ send, timerApi = globalThis } = {}) {
    this.send = requiredFunction(send, "send");
    this.timerApi = timerApi;
    this.currentMs = null;
    this.interval = null;
  }

  get active() {
    return this.interval != null;
  }

  setMode(mode, { active = true } = {}) {
    const intervalMs = BEACON_INTERVALS_MS[mode] || DEFAULT_BEACON_INTERVAL_MS;
    if (this.interval && intervalMs === this.currentMs) return false;

    this.currentMs = intervalMs;
    this.stop();
    if (!active) return false;

    this.interval = this.timerApi.setInterval(() => this.send(), intervalMs);
    return true;
  }

  stop() {
    if (this.interval) this.timerApi.clearInterval(this.interval);
    this.interval = null;
  }

  destroy() {
    this.stop();
    this.currentMs = null;
  }
}

export function createBeaconScheduler(options) {
  return new BeaconScheduler(options);
}
