export const SYNC_LOCK_MS = 1_500;

/**
 * Runs delayed host commands under a generation counter and owns the short
 * sync lock that stops the host bridge from echoing corrections back as
 * user actions.
 */
export class SyncCommandScheduler {
  constructor({ lockMs = SYNC_LOCK_MS, timerApi = globalThis } = {}) {
    this.timerApi = timerApi;
    this.lockMs = lockMs;
    this.generation = 0;
    this.timers = new Set();
    this.locked = false;
    this.lockTimer = null;
  }

  isCurrent(generation) {
    return generation === this.generation;
  }

  schedule(callback, delay = 0) {
    const generation = this.generation;
    const timer = this.timerApi.setTimeout(() => {
      this.timers.delete(timer);
      if (generation === this.generation) callback();
    }, delay);
    this.timers.add(timer);
    return generation;
  }

  cancelAll() {
    this.generation += 1;
    for (const timer of this.timers) this.timerApi.clearTimeout(timer);
    this.timers.clear();
  }

  lock() {
    this.locked = true;
    if (this.lockTimer) this.timerApi.clearTimeout(this.lockTimer);
    this.lockTimer = this.timerApi.setTimeout(() => {
      this.locked = false;
      this.lockTimer = null;
    }, this.lockMs);
  }

  unlock() {
    if (this.lockTimer) this.timerApi.clearTimeout(this.lockTimer);
    this.lockTimer = null;
    this.locked = false;
  }

  destroy() {
    this.cancelAll();
    this.unlock();
  }
}

export function createSyncCommandScheduler(options) {
  return new SyncCommandScheduler(options);
}
