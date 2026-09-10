import { ResolverError, normalizeInput } from './errors.js';

export class ResolutionQueue {
  constructor(resolve, { concurrency = 2, maxQueue = 2 } = {}) {
    this.resolve = resolve;
    this.concurrency = concurrency;
    this.maxQueue = maxQueue;
    this.active = 0;
    this.pending = [];
    this.inFlight = new Map();
  }

  run(rawInput) {
    const input = normalizeInput(rawInput);
    const key = JSON.stringify([input.tmdb_id || input.imdb_id, input.audio]);
    if (this.inFlight.has(key)) return this.inFlight.get(key);
    if (this.active >= this.concurrency && this.pending.length >= this.maxQueue) {
      return Promise.reject(new ResolverError('busy'));
    }
    const work = new Promise((resolve, reject) => {
      this.pending.push({ input, resolve, reject });
    });
    const tracked = work.finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, tracked);
    this.drain();
    return tracked;
  }

  drain() {
    while (this.active < this.concurrency && this.pending.length) {
      const job = this.pending.shift();
      this.active++;
      Promise.resolve().then(() => this.resolve(job.input)).then(job.resolve, job.reject).finally(() => {
        this.active--; this.drain();
      });
    }
  }
}
