export const CLOCK_PING_ATTEMPTS = 5;
export const CLOCK_PING_TIMEOUT_MS = 2_000;
export const CLOCK_PING_GAP_MS = 200;
export const CLOCK_MAX_RTT_MS = 1_000;
export const CLOCK_BEST_SAMPLES = 3;

function requiredFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`ClockSync requires ${name}()`);
  }
  return value;
}

/**
 * Estimates the offset between the browser clock and the room server clock.
 *
 * Sends a bounded burst of pings, keeps the samples with the lowest RTT and
 * uses their median offset. `serverNow()` then lets the viewer schedule host
 * commands against `target_time` values stamped by the server.
 */
export class ClockSync {
  constructor({
    attempts = CLOCK_PING_ATTEMPTS,
    now = () => Date.now(),
    push,
    timerApi = globalThis,
  } = {}) {
    this.push = requiredFunction(push, "push");
    this.now = now;
    this.timerApi = timerApi;
    this.attempts = attempts;

    this.offset = 0;
    this.ready = false;
    this.samples = [];
    this.pingId = 0;
    this.pingAttempts = 0;
    this.pings = new Map();
    this.pingTimer = null;
  }

  estimate() {
    this.ready = false;
    this.samples = [];
    this.pingAttempts = 0;
    this.cancel();
    this.sendPing();
  }

  handlePong(data) {
    const ping = this.pings.get(data?.id);
    const serverTime = Number(data?.server_time);
    if (!ping || !Number.isFinite(serverTime)) return false;

    this.timerApi.clearTimeout(ping.timeout);
    this.pings.delete(data.id);

    const receivedAt = this.now();
    const rtt = receivedAt - ping.startedAt;
    if (rtt >= 0 && rtt < CLOCK_MAX_RTT_MS) {
      this.samples.push({ offset: (ping.startedAt + receivedAt) / 2 - serverTime, rtt });
    }

    this.schedulePing();
    return true;
  }

  serverNow() {
    return this.now() - this.offset;
  }

  cancel() {
    if (this.pingTimer) this.timerApi.clearTimeout(this.pingTimer);
    this.pingTimer = null;
    for (const ping of this.pings.values()) this.timerApi.clearTimeout(ping.timeout);
    this.pings.clear();
  }

  snapshot() {
    return Object.freeze({
      attempts: this.pingAttempts,
      offset: this.offset,
      pending: this.pings.size,
      ready: this.ready,
      samples: this.samples.length,
    });
  }

  sendPing() {
    if (this.pingAttempts >= this.attempts) {
      this.compute();
      return;
    }

    this.pingAttempts += 1;
    this.pingId += 1;
    const id = this.pingId;
    const startedAt = this.now();
    const timeout = this.timerApi.setTimeout(() => {
      this.pings.delete(id);
      this.schedulePing();
    }, CLOCK_PING_TIMEOUT_MS);

    this.pings.set(id, { startedAt, timeout });
    this.push("wp_clock_ping", { id, client_time: startedAt });
  }

  schedulePing() {
    if (this.pingTimer) this.timerApi.clearTimeout(this.pingTimer);
    this.pingTimer = this.timerApi.setTimeout(() => {
      this.pingTimer = null;
      this.sendPing();
    }, CLOCK_PING_GAP_MS);
  }

  compute() {
    if (this.samples.length === 0) return false;

    const offsets = [...this.samples]
      .sort((left, right) => left.rtt - right.rtt)
      .slice(0, CLOCK_BEST_SAMPLES)
      .map((sample) => sample.offset)
      .sort((left, right) => left - right);

    this.offset = offsets[Math.floor(offsets.length / 2)];
    this.ready = true;
    return true;
  }
}

export function createClockSync(options) {
  return new ClockSync(options);
}
