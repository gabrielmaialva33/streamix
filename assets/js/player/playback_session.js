import { ENGINE_ID, normalizeEngineId } from "./engine_contract.js";

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

  begin({ contentType = "unknown", streamType = "unknown", displayMode = "browser" } = {}) {
    this.active = {
      batchId: this.batchId(),
      startedAt: this.now(),
      playingAt: null,
      bufferingAt: null,
      bufferingDurationMs: 0,
      bufferCount: 0,
      errorCount: 0,
      fallbackCount: 0,
      mutedMismatch: false,
      engine: ENGINE_ID.UNKNOWN,
      contentType,
      streamType,
      displayMode,
    };

    return this.active.batchId;
  }

  selectEngine(engine) {
    if (this.active) this.active.engine = normalizeEngineId(engine);
  }

  markPlaying() {
    if (!this.active) return;
    this.active.playingAt ??= this.now();
    this.setBuffering(false);
  }

  setBuffering(buffering) {
    if (!this.active) return;

    if (buffering && this.active.bufferingAt === null) {
      this.active.bufferingAt = this.now();
      this.active.bufferCount += 1;
    } else if (!buffering && this.active.bufferingAt !== null) {
      this.active.bufferingDurationMs += this.now() - this.active.bufferingAt;
      this.active.bufferingAt = null;
    }
  }

  recordError() {
    if (this.active) this.active.errorCount += 1;
  }

  recordFallback(engine) {
    if (!this.active) return;

    const target = normalizeEngineId(engine);
    if (this.active.engine !== target) this.active.fallbackCount += 1;
    this.active.engine = target;
  }

  markMutedMismatch() {
    if (this.active) this.active.mutedMismatch = true;
  }

  finish(outcome = "completed") {
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
