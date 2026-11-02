/** One retry budget spans engine changes and token refreshes. Only user retry starts over. */
export class PlaybackRecoveryGuard {
  constructor({
    now = () => performance.now(),
    timerApi = globalThis,
    onExhausted = () => {},
    onStable = () => {},
    startupMs = 30_000,
    recoveryMs = 20_000,
    stableMs = 20_000,
    windowMs = 60_000,
    maxAttempts = 6,
  } = {}) {
    Object.assign(this, {
      now,
      timerApi,
      onExhausted,
      onStable,
      startupMs,
      recoveryMs,
      stableMs,
      windowMs,
      maxAttempts,
    });
    this.attempts = [];
    this.deadline = null;
    this.stability = null;
    this.terminal = false;
    this.started = false;
    this.destroyed = false;
  }

  begin() {
    if (this.destroyed) return;
    this.clearTimers();
    this.attempts = [];
    this.terminal = false;
    this.started = true;
    this.hasPlayed = false;
    this.suspended = false;
    this.armDeadline(this.startupMs, "startup_deadline");
  }

  armDeadline(ms, reason) {
    if (this.deadline !== null || this.terminal || this.destroyed) return;
    this.deadline = this.timerApi.setTimeout(() => this.exhaust(reason), ms);
  }

  recover() {
    if (!this.started || this.terminal || this.destroyed) return;
    this.pause();
    if (this.suspended) return;
    this.armDeadline(this.recoveryMs, "recovery_deadline");
  }

  attempt() {
    if (this.terminal || this.destroyed) return false;
    this.recover();
    const now = this.now();
    this.attempts = this.attempts.filter((at) => now - at < this.windowMs);
    if (this.attempts.length >= this.maxAttempts) {
      this.exhaust("retry_budget");
      return false;
    }
    this.attempts.push(now);
    return true;
  }

  playing() {
    if (this.terminal || this.destroyed) return;
    this.hasPlayed = true;
    this.suspended = false;
    this.timerApi.clearTimeout(this.deadline);
    this.deadline = null;
    if (this.stability !== null) return;
    this.stability = this.timerApi.setTimeout(() => {
      this.stability = null;
      this.attempts = [];
      this.onStable();
    }, this.stableMs);
  }

  suspend() {
    this.suspended = true;
    this.clearTimers();
  }

  resume() {
    if (!this.suspended || this.terminal || this.destroyed) return;
    this.suspended = false;
    this.armDeadline(
      this.hasPlayed ? this.recoveryMs : this.startupMs,
      this.hasPlayed ? "recovery_deadline" : "startup_deadline",
    );
  }

  pause() {
    this.timerApi.clearTimeout(this.stability);
    this.stability = null;
  }

  exhaust(reason) {
    if (this.terminal || this.destroyed) return;
    this.finish();
    this.onExhausted(reason);
  }

  finish() {
    this.terminal = true;
    this.clearTimers();
  }

  clearTimers() {
    this.pause();
    this.timerApi.clearTimeout(this.deadline);
    this.deadline = null;
  }

  destroy() {
    this.destroyed = true;
    this.clearTimers();
  }
}
