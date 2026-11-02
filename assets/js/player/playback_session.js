import { ENGINE_ID, normalizeEngineId } from "./engine_contract.js";
import { clientRevision, endReason, engineReason } from "./playback_reasons.js";

const defaultNow = () => globalThis.performance?.now?.() ?? Date.now();

const defaultBatchId = () =>
  globalThis.crypto?.randomUUID?.() ||
  `playback-${Date.now()}-${Math.random().toString(16).slice(2)}`;

export class PlaybackSession {
  constructor({ now = defaultNow, batchId = defaultBatchId } = {}) {
    this.now = now;
    this.batchId = batchId;
    this.active = null;
  }

  begin({
    contentType = "unknown",
    streamType = "unknown",
    displayMode = "browser",
    startedAt = this.now(),
    clientRevision: revision,
  } = {}) {
    this.active = {
      batchId: this.batchId(),
      startedAt: Number.isFinite(startedAt) ? Math.min(startedAt, this.now()) : this.now(),
      marks: {},
      playingAt: null,
      bufferingAt: null,
      bufferingDurationMs: 0,
      bufferCount: 0,
      errorCount: 0,
      fallbackCount: 0,
      mutedMismatch: false,
      engine: ENGINE_ID.UNKNOWN,
      engineReason: "unknown",
      clientRevision: clientRevision(revision),
      contentType,
      streamType,
      displayMode,
    };

    return this.active.batchId;
  }

  selectEngine(engine, reason) {
    if (this.active) {
      this.active.engine = normalizeEngineId(engine);
      if (reason !== undefined) this.active.engineReason = engineReason(reason);
    }
  }

  markPlaying() {
    if (!this.active) return;
    if (this.active.playingAt !== null) this.setBuffering(false);
  }

  markStage(stage) {
    if (!this.active || !["url", "manifest", "metadata", "play", "frame"].includes(stage)) return;
    this.active.marks[stage] ??= Math.max(0, Math.round(this.now() - this.active.startedAt));
  }

  markFirstFrame() {
    if (!this.active) return;
    this.active.playingAt ??= this.now();
    this.markStage("frame");
    this.setBuffering(false);
  }

  setBuffering(buffering) {
    if (!this.active || this.active.playingAt === null) return;

    if (buffering && this.active.bufferingAt === null) {
      this.active.bufferingAt = this.now();
      if (this.active.playingAt !== null) this.active.bufferCount += 1;
    } else if (!buffering && this.active.bufferingAt !== null) {
      this.active.bufferingDurationMs += this.now() - this.active.bufferingAt;
      this.active.bufferingAt = null;
    }
  }

  recordError() {
    if (this.active) this.active.errorCount += 1;
  }

  recordFallback(engine, reason) {
    if (!this.active) return;

    const target = normalizeEngineId(engine);
    if (this.active.engine !== target) this.active.fallbackCount += 1;
    this.active.engine = target;
    if (reason !== undefined) this.active.engineReason = engineReason(reason);
  }

  markMutedMismatch() {
    if (this.active) this.active.mutedMismatch = true;
  }

  finish(outcome = "completed", reason) {
    if (!this.active) return null;

    this.setBuffering(false);
    const session = this.active;
    const endedAt = this.now();
    this.active = null;

    return {
      batch_id: session.batchId,
      kind: "playback",
      event: "playback_session",
      outcome,
      end_reason: endReason(
        reason ??
          (outcome === "completed"
            ? "completed"
            : outcome === "restarted"
              ? "user_retry"
              : outcome === "cancelled"
                ? session.playingAt === null
                  ? "navigation"
                  : "first_frame_then_user_left"
                : "unknown"),
      ),
      engine_reason: session.engineReason,
      client_revision: session.clientRevision,
      engine: session.engine,
      content_type: session.contentType,
      stream_type: session.streamType,
      display_mode: session.displayMode,
      ttff_ms:
        session.playingAt === null
          ? undefined
          : Math.max(0, Math.round(session.playingAt - session.startedAt)),
      buffer_count: session.bufferCount,
      buffer_duration_ms: Math.max(0, Math.round(session.bufferingDurationMs)),
      session_duration_ms: Math.max(0, Math.round(endedAt - session.startedAt)),
      error_count: session.errorCount,
      fallback_count: session.fallbackCount,
      muted_mismatch: session.mutedMismatch,
    };
  }
}
