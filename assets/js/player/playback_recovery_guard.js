/** One retry budget spans engine changes and token refreshes. Only user retry starts over. */
export class PlaybackRecoveryGuard {
  constructor({
    now = () => performance.now(),
    timerApi = globalThis,
    onExhausted = () => {},
    onStable = () => {},
    onStartupDeadline = () => false,
    bootstrapMs = 60_000,
    totalStartupMs = 90_000,
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
      onStartupDeadline,
      bootstrapMs,
      totalStartupMs,
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
    this.bootstrapUsed = false;
    this.bootstrapping = false;
    this.deadlineRecovered = false;
    this.startupEndsAt = this.now() + this.totalStartupMs;
    this.suspendedDeadline = null;
    this.suspended = false;
    this.armDeadline(this.startupMs, "startup_deadline");
  }

  armDeadline(ms, reason) {
    if (this.deadline !== null || this.terminal || this.destroyed) return;
    this.deadlineAt = this.now() + ms;
    this.deadlineReason = reason;
    this.deadline = this.timerApi.setTimeout(() => this.deadlineExpired(reason), ms);
  }

  // Import/init and libmedia pipeline preparation (including lazy WASM) precede the frame wait.
  bootstrap() {
    if (this.bootstrapUsed || this.hasPlayed || this.deadlineRecovered || this.terminal) return;
    this.bootstrapUsed = true;
    this.bootstrapping = true;
    this.replaceStartupDeadline(this.bootstrapMs);
  }

  awaitFrame() {
    if (!this.bootstrapping || this.hasPlayed || this.deadlineRecovered || this.terminal) return;
    this.bootstrapping = false;
    this.replaceStartupDeadline(this.startupMs);
  }

  replaceStartupDeadline(ms) {
    if (this.suspended) {
      this.suspendedDeadline = { ms, reason: "startup_deadline" };
      return;
    }
    this.timerApi.clearTimeout(this.deadline);
    this.deadline = null;
    this.armDeadline(
      Math.max(0, Math.min(ms, this.startupEndsAt - this.now())),
      "startup_deadline",
    );
  }

  deadlineExpired(reason) {
    this.deadline = null;
    if (this.terminal || this.destroyed) return;
    if (!this.hasPlayed && !this.deadlineRecovered) {
      this.deadlineRecovered = true;
      // Arm before invoking product policy: synchronous activation/retry must share this budget.
      this.armDeadline(this.recoveryMs, "recovery_deadline");
      if (this.onStartupDeadline(reason) === true) return;
    }
    this.exhaust(reason);
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
    if (!this.suspended) {
      this.suspendedAt = this.now();
      this.suspendedDeadline =
        this.deadline === null
          ? null
          : {
              ms: Math.max(0, this.deadlineAt - this.now()),
              reason: this.deadlineReason,
            };
    }
    this.suspended = true;
    this.clearTimers();
  }

  resume() {
    if (!this.suspended || this.terminal || this.destroyed) return;
    this.startupEndsAt += this.now() - this.suspendedAt;
    this.suspended = false;
    const remaining = this.suspendedDeadline;
    this.suspendedDeadline = null;
    if (this.hasPlayed || this.deadlineRecovered) {
      this.armDeadline(remaining?.ms ?? this.recoveryMs, "recovery_deadline");
    } else {
      this.replaceStartupDeadline(
        remaining?.ms ?? (this.bootstrapping ? this.bootstrapMs : this.startupMs),
      );
    }
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
