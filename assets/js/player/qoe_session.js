function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") throw new TypeError(`QoESession ${name} must be a function`);
  return value;
}

function safeEmit(callback, event, snapshot) {
  if (!callback) return;
  try {
    callback(event, snapshot);
  } catch {
    // Telemetry must never become a playback failure source.
  }
}

function normalizeEngine(value) {
  return typeof value === "string" && value ? value.slice(0, 40) : "unknown";
}

function normalizeReason(value) {
  return value == null ? null : String(value).slice(0, 120);
}

/**
 * Session-scoped Quality of Experience accumulator.
 *
 * It deliberately stores only bounded numeric diagnostics and engine labels;
 * URLs, tokens, content names and user identifiers never enter the snapshot.
 */
export class QoESession {
  constructor({ now = () => performance.now(), emit = null } = {}) {
    if (typeof now !== "function") throw new TypeError("QoESession now must be a function");
    this.now = now;
    this.emit = optionalCallback(emit, "emit");
    this.reset();
  }

  begin({ sessionId = 0, engine = "unknown", live = false } = {}) {
    const at = this.timestamp();
    this.active = true;
    this.finished = false;
    this.sessionId = Math.max(0, Math.trunc(finiteNonNegative(sessionId)));
    this.engine = normalizeEngine(engine);
    this.live = live === true;
    this.startedAt = at;
    this.metadataAt = null;
    this.readyAt = null;
    this.firstPlayingAt = null;
    this.finishedAt = null;
    this.stallStartedAt = null;
    this.rebufferCount = 0;
    this.rebufferDurationMs = 0;
    this.fallbackCount = 0;
    this.recoveryCount = 0;
    this.errorCount = 0;
    this.fatalErrorCount = 0;
    this.engineChanges = 0;
    this.lastReason = null;
    this.currentTime = 0;
    this.duration = 0;
    this.liveLatency = null;
    this.bandwidthEstimate = null;
    this.droppedFrames = 0;
    this.decodedFrames = 0;
    this.emitSnapshot("begin");
    return this.sessionId;
  }

  setEngine(engine) {
    const normalized = normalizeEngine(engine);
    if (this.engine !== "unknown" && this.engine !== normalized) this.engineChanges += 1;
    this.engine = normalized;
    this.emitSnapshot("engine");
  }

  markMetadata() {
    if (!this.active || this.metadataAt != null) return false;
    this.metadataAt = this.timestamp();
    this.emitSnapshot("metadata");
    return true;
  }

  markReady() {
    if (!this.active || this.readyAt != null) return false;
    this.readyAt = this.timestamp();
    this.emitSnapshot("ready");
    return true;
  }

  markPlaying() {
    if (!this.active) return false;
    if (this.firstPlayingAt == null) this.firstPlayingAt = this.timestamp();
    this.endStall();
    this.emitSnapshot("playing");
    return true;
  }

  startStall() {
    if (!this.active || this.stallStartedAt != null) return false;
    this.stallStartedAt = this.timestamp();
    this.rebufferCount += 1;
    this.emitSnapshot("stall_start");
    return true;
  }

  endStall() {
    if (this.stallStartedAt == null) return false;
    this.rebufferDurationMs += Math.max(0, this.timestamp() - this.stallStartedAt);
    this.stallStartedAt = null;
    this.emitSnapshot("stall_end");
    return true;
  }

  recordRecovery(reason = null) {
    if (!this.active) return false;
    this.recoveryCount += 1;
    this.lastReason = normalizeReason(reason);
    this.emitSnapshot("recovery");
    return true;
  }

  recordFallback({ from = null, to = null, reason = null } = {}) {
    if (!this.active) return false;
    this.fallbackCount += 1;
    this.lastReason = normalizeReason(reason);
    if (to) this.setEngine(to);
    this.emitSnapshot("fallback");
    return Object.freeze({ from: normalizeEngine(from), to: normalizeEngine(to) });
  }

  recordError({ fatal = false, reason = null } = {}) {
    if (!this.active) return false;
    this.errorCount += 1;
    if (fatal) this.fatalErrorCount += 1;
    this.lastReason = normalizeReason(reason);
    this.emitSnapshot(fatal ? "fatal_error" : "error");
    return true;
  }

  updateTransport({
    currentTime,
    duration,
    liveLatency,
    bandwidthEstimate,
    droppedFrames,
    decodedFrames,
  } = {}) {
    if (!this.active) return false;
    if (currentTime != null) this.currentTime = finiteNonNegative(currentTime);
    if (duration != null) this.duration = finiteNonNegative(duration);
    if (liveLatency != null) this.liveLatency = finiteNonNegative(liveLatency);
    if (bandwidthEstimate != null) {
      this.bandwidthEstimate = finiteNonNegative(bandwidthEstimate);
    }
    if (droppedFrames != null) this.droppedFrames = finiteNonNegative(droppedFrames);
    if (decodedFrames != null) this.decodedFrames = finiteNonNegative(decodedFrames);
    return true;
  }

  finish(reason = "ended") {
    if (!this.active || this.finished) return false;
    this.endStall();
    this.finished = true;
    this.active = false;
    this.finishedAt = this.timestamp();
    this.lastReason = normalizeReason(reason);
    this.emitSnapshot("finish");
    return true;
  }

  snapshot(at = this.timestamp()) {
    const effectiveEnd = this.finishedAt ?? at;
    const wallDurationMs = this.startedAt == null ? 0 : Math.max(0, effectiveEnd - this.startedAt);
    const activeStallMs = this.stallStartedAt == null ? 0 : Math.max(0, at - this.stallStartedAt);
    const rebufferDurationMs = this.rebufferDurationMs + activeStallMs;
    const playbackWindowMs = Math.max(0, wallDurationMs - this.startupMs());
    const rebufferRatio =
      playbackWindowMs > 0 ? Math.min(1, rebufferDurationMs / playbackWindowMs) : 0;
    const frameDropRatio =
      this.decodedFrames > 0 ? Math.min(1, this.droppedFrames / this.decodedFrames) : 0;

    return Object.freeze({
      sessionId: this.sessionId,
      engine: this.engine,
      live: this.live,
      active: this.active,
      finished: this.finished,
      startupMs: this.startupMs(),
      metadataMs: this.elapsed(this.metadataAt),
      readyMs: this.elapsed(this.readyAt),
      wallDurationMs,
      rebufferCount: this.rebufferCount,
      rebufferDurationMs,
      rebufferRatio,
      fallbackCount: this.fallbackCount,
      recoveryCount: this.recoveryCount,
      errorCount: this.errorCount,
      fatalErrorCount: this.fatalErrorCount,
      engineChanges: this.engineChanges,
      currentTime: this.currentTime,
      duration: this.duration,
      liveLatency: this.liveLatency,
      bandwidthEstimate: this.bandwidthEstimate,
      droppedFrames: this.droppedFrames,
      decodedFrames: this.decodedFrames,
      frameDropRatio,
      lastReason: this.lastReason,
    });
  }

  startupMs() {
    return this.elapsed(this.firstPlayingAt);
  }

  elapsed(timestamp) {
    if (timestamp == null || this.startedAt == null) return null;
    return Math.max(0, timestamp - this.startedAt);
  }

  emitSnapshot(event) {
    safeEmit(this.emit, event, this.snapshot());
  }

  timestamp() {
    const value = Number(this.now());
    if (!Number.isFinite(value)) throw new TypeError("QoESession clock must be finite");
    return value;
  }

  reset() {
    this.active = false;
    this.finished = false;
    this.sessionId = 0;
    this.engine = "unknown";
    this.live = false;
    this.startedAt = null;
    this.metadataAt = null;
    this.readyAt = null;
    this.firstPlayingAt = null;
    this.finishedAt = null;
    this.stallStartedAt = null;
    this.rebufferCount = 0;
    this.rebufferDurationMs = 0;
    this.fallbackCount = 0;
    this.recoveryCount = 0;
    this.errorCount = 0;
    this.fatalErrorCount = 0;
    this.engineChanges = 0;
    this.lastReason = null;
    this.currentTime = 0;
    this.duration = 0;
    this.liveLatency = null;
    this.bandwidthEstimate = null;
    this.droppedFrames = 0;
    this.decodedFrames = 0;
  }
}

export function createQoESession(options = {}) {
  return new QoESession(options);
}
