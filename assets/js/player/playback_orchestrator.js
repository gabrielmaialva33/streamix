import { normalizeEngineId, PLAYBACK_STATE } from "./engine_contract.js";
import { createEngineRegistry } from "./engine_registry.js";
import { createPlaybackStateObserver } from "./playback_state_observer.js";
import { createQoESession } from "./qoe_session.js";
import { createTrackCoordinator } from "./track_coordinator.js";

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`PlaybackOrchestrator ${name} must be a function`);
  }
  return value;
}

function safeCall(callback, ...args) {
  if (!callback) return;
  try {
    callback(...args);
  } catch {
    // Observability callbacks must never become playback failures.
  }
}

function qoeMetadata(event, snapshot) {
  return {
    qoe_event: event,
    session_id: snapshot.sessionId,
    engine: snapshot.engine,
    live: snapshot.live,
    startup_ms: snapshot.startupMs,
    metadata_ms: snapshot.metadataMs,
    ready_ms: snapshot.readyMs,
    wall_duration_ms: snapshot.wallDurationMs,
    rebuffer_count: snapshot.rebufferCount,
    rebuffer_duration_ms: snapshot.rebufferDurationMs,
    rebuffer_ratio: snapshot.rebufferRatio,
    fallback_count: snapshot.fallbackCount,
    recovery_count: snapshot.recoveryCount,
    error_count: snapshot.errorCount,
    fatal_error_count: snapshot.fatalErrorCount,
    engine_changes: snapshot.engineChanges,
    current_time: snapshot.currentTime,
    duration: snapshot.duration,
    live_latency: snapshot.liveLatency,
    bandwidth_estimate: snapshot.bandwidthEstimate,
    dropped_frames: snapshot.droppedFrames,
    decoded_frames: snapshot.decodedFrames,
    frame_drop_ratio: snapshot.frameDropRatio,
    qoe_reason: snapshot.lastReason,
  };
}

/**
 * Coordinates playback sessions, the active engine and lifecycle state.
 *
 * Source selection and cross-engine fallback remain product policy owned by the
 * hook. The orchestrator only provides deterministic ownership and state.
 */
export class PlaybackOrchestrator {
  constructor({
    registry = null,
    createObserver = createPlaybackStateObserver,
    reportLifecycle = null,
    logInvalid = null,
    onEngineChange = null,
  } = {}) {
    if (typeof createObserver !== "function") {
      throw new TypeError("PlaybackOrchestrator createObserver must be a function");
    }

    this.reportLifecycle = optionalCallback(reportLifecycle, "reportLifecycle");
    this.logInvalid = optionalCallback(logInvalid, "logInvalid");
    this.onEngineChange = optionalCallback(onEngineChange, "onEngineChange");
    this.createObserver = createObserver;
    this.registry =
      registry ??
      createEngineRegistry({
        onChange: (change) => this.handleEngineChange(change),
        onDestroyError: (error, id) =>
          safeCall(this.reportLifecycle, "player_engine_destroy_error", {
            engine: id,
            error_name: error?.name ?? "Error",
          }),
      });
    this.trackCoordinator = createTrackCoordinator({
      getEngine: () => this.registry.current(),
      onChange: (change) =>
        safeCall(this.reportLifecycle, "player_track_changed", {
          session_id: this.sessionId,
          engine: this.registry.currentId(),
          track_kind: change.kind,
          track_id: change.trackId,
        }),
      onError: (error, method) =>
        safeCall(this.reportLifecycle, "player_track_error", {
          session_id: this.sessionId,
          engine: this.registry.currentId(),
          operation: method,
          error_name: error?.name ?? "Error",
        }),
    });
    this.qoe = createQoESession({
      emit: (event, snapshot) =>
        safeCall(this.reportLifecycle, "player_qoe", qoeMetadata(event, snapshot)),
    });
    this.sessionId = 0;
    this.observer = null;
    this.destroyed = false;
  }

  begin(metadata = {}) {
    this.assertActive();
    this.sessionId += 1;
    this.observer = this.createObserver({
      reportLifecycle: this.reportLifecycle,
      logInvalid: this.logInvalid,
    });
    this.observer.begin(this.sessionId);
    this.qoe.begin({
      sessionId: this.sessionId,
      engine: this.registry.currentId() ?? "unknown",
      live: metadata.live === true,
    });

    if (Object.keys(metadata).length > 0) {
      safeCall(this.reportLifecycle, "player_session_started", {
        session_id: this.sessionId,
        ...metadata,
      });
    }

    return this.sessionId;
  }

  isCurrent(sessionId) {
    return !this.destroyed && Number(sessionId) === this.sessionId;
  }

  observe(nextState, reason, metadata = {}) {
    if (this.destroyed || !this.observer) return null;
    const transition = this.observer.observe(nextState, reason, {
      session_id: this.sessionId,
      engine: this.registry.currentId(),
      ...metadata,
    });

    if (transition?.accepted && transition.changed) {
      this.observeQoeState(nextState, reason, metadata);
    }

    return transition;
  }

  activateEngine(id, engine, { releasePrevious = true, ...options } = {}) {
    this.assertActive();
    const engineId = normalizeEngineId(id);
    const previousId = this.registry.currentId();

    if (releasePrevious && previousId && previousId !== engineId) {
      this.registry.release(previousId);
    }

    const active = this.registry.registerAndActivate(engineId, engine, options);
    this.qoe.setEngine(engineId);
    this.observe(PLAYBACK_STATE.LOADING, "engine_activated", {
      engine: engineId,
      previous_engine: previousId,
    });
    return active;
  }

  currentEngine() {
    return this.registry.current();
  }

  currentEngineId() {
    return this.registry.currentId();
  }

  capabilities() {
    return this.trackCoordinator.capabilities();
  }

  trackSnapshot() {
    return this.trackCoordinator.snapshot();
  }

  selectAudioTrack(trackId) {
    return this.trackCoordinator.selectAudioTrack(trackId);
  }

  selectSubtitleTrack(trackId) {
    return this.trackCoordinator.selectSubtitleTrack(trackId);
  }

  loadExternalSubtitle(options) {
    return this.trackCoordinator.loadExternalSubtitle(options);
  }

  setSubtitleDelay(delayMs) {
    return this.trackCoordinator.setSubtitleDelay(delayMs);
  }

  releaseEngine(id, options = {}) {
    return this.registry.release(id, options);
  }

  recordFallback(details = {}) {
    return this.qoe.recordFallback(details);
  }

  recordError(details = {}) {
    return this.qoe.recordError(details);
  }

  updateTransport(snapshot = {}) {
    return this.qoe.updateTransport({
      currentTime: snapshot.currentTime,
      duration: snapshot.duration,
      liveLatency: snapshot.latency ?? snapshot.liveLatency,
      bandwidthEstimate: snapshot.bandwidthEstimate,
      droppedFrames: snapshot.droppedFrames,
      decodedFrames: snapshot.decodedFrames,
    });
  }

  ready(metadata = {}) {
    return this.observe(PLAYBACK_STATE.READY, "engine_ready", metadata);
  }

  playing(metadata = {}) {
    return this.observe(PLAYBACK_STATE.PLAYING, "playback_started", metadata);
  }

  stalled(metadata = {}) {
    return this.observe(PLAYBACK_STATE.STALLED, "playback_stalled", metadata);
  }

  recovering(metadata = {}) {
    return this.observe(PLAYBACK_STATE.RECOVERING, "playback_recovering", metadata);
  }

  ended(metadata = {}) {
    return this.observe(PLAYBACK_STATE.ENDED, "playback_ended", metadata);
  }

  terminal(metadata = {}) {
    return this.observe(PLAYBACK_STATE.TERMINAL, "playback_terminal", metadata);
  }

  snapshot() {
    return Object.freeze({
      sessionId: this.sessionId,
      destroyed: this.destroyed,
      engineId: this.registry.currentId(),
      lifecycle: this.observer?.snapshot() ?? null,
      registry: this.registry.snapshot(),
      tracks: this.trackCoordinator.snapshot(),
      qoe: this.qoe.snapshot(),
    });
  }

  reset({ destroyEngines = false } = {}) {
    if (this.destroyed) return false;
    if (destroyEngines) {
      this.registry.destroy();
      this.registry = createEngineRegistry({
        onChange: (change) => this.handleEngineChange(change),
      });
    } else {
      this.registry.deactivate();
    }
    this.observer = null;
    this.qoe.reset();
    return true;
  }

  destroy() {
    if (this.destroyed) return false;
    if (this.observer) {
      this.observer.observe(PLAYBACK_STATE.DESTROYED, "orchestrator_destroyed", {
        session_id: this.sessionId,
      });
    }
    this.qoe.finish("destroyed");
    this.destroyed = true;
    this.registry.destroy();
    this.observer = null;
    return true;
  }

  observeQoeState(nextState, reason, metadata) {
    switch (nextState) {
      case PLAYBACK_STATE.READY:
        this.qoe.markReady();
        break;
      case PLAYBACK_STATE.PLAYING:
        this.qoe.markPlaying();
        break;
      case PLAYBACK_STATE.STALLED:
        this.qoe.startStall();
        break;
      case PLAYBACK_STATE.RECOVERING:
        this.qoe.recordRecovery(reason);
        break;
      case PLAYBACK_STATE.ENDED:
        this.qoe.finish("ended");
        break;
      case PLAYBACK_STATE.TERMINAL:
        this.qoe.recordError({ fatal: true, reason });
        this.qoe.finish("terminal");
        break;
      case PLAYBACK_STATE.DESTROYED:
        this.qoe.finish("destroyed");
        break;
      default:
        if (metadata?.metadata_loaded === true) this.qoe.markMetadata();
    }
  }

  handleEngineChange(change) {
    safeCall(this.onEngineChange, change);
    safeCall(this.reportLifecycle, "player_engine_changed", {
      previous_engine: change.previousId,
      engine: change.engineId,
      session_id: this.sessionId,
    });
  }

  assertActive() {
    if (this.destroyed) throw new Error("PlaybackOrchestrator has been destroyed");
  }
}

export function createPlaybackOrchestrator(options = {}) {
  return new PlaybackOrchestrator(options);
}
