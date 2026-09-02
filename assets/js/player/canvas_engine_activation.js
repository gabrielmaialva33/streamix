import { playerLogger as log } from "../core/logger.js";
import { ENGINE_ID } from "./engine_contract.js";
import {
  assertActivationHost,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "./playback_engine_activation.js";
import { createPlaybackEngineAdapter } from "./playback_engine_adapter.js";

export const CANVAS_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
  "disablePiPForCanvasPlayback",
  "emitPlaybackEvent",
  "flushPlaybackMetrics",
  "getContentType",
  "getPresentation",
  "getVideo",
  "handlePlaybackEnded",
  "handlePlaybackPaused",
  "handlePlaybackStarted",
  "markPlaying",
  "recordPlaybackError",
  "reportLifecycle",
  "reportProgress",
  "setNativePlaybackEventsSuppressed",
  "setPlaybackSystemState",
  "takeResumeTime",
  "trackManagedEngine",
  "tryAVPlayerFallback",
  "updateTimeUI",
]);

const defaultDependencies = {
  createPlaybackEngineAdapter,
};

/**
 * Shared skeleton for the GPU/canvas engines (avbridge, h265web).
 *
 * Both lazily load a wrapper module, wrap it in the playback engine adapter,
 * register it as a managed engine, load with a resume position, seek, play
 * and fall back to AVPlayer on any failure. Subclasses supply the wrapper,
 * the engine slot on the host and the few engine-specific hooks.
 */
export class CanvasEngineActivation {
  constructor({ dependencies = {}, host, hostMethods, logger = log, name } = {}) {
    this.host = assertActivationHost(
      host,
      hostMethods ?? CANVAS_ENGINE_ACTIVATION_HOST_METHODS,
      name ?? "CanvasEngineActivation",
    );
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;
  }

  // Subclass surface. Each subclass owns one engine slot on the host.
  get id() {
    throw new Error("CanvasEngineActivation subclasses must define id");
  }

  get selection() {
    throw new Error("CanvasEngineActivation subclasses must define selection");
  }

  get label() {
    return this.id;
  }

  get logTag() {
    return this.label;
  }

  get resetsNativePlaybackEvents() {
    return false;
  }

  get notifiesStartAfterPlay() {
    return false;
  }

  loadModule() {
    throw new Error("CanvasEngineActivation subclasses must implement loadModule()");
  }

  createWrapper(_module) {
    throw new Error("CanvasEngineActivation subclasses must implement createWrapper()");
  }

  getEngine() {
    throw new Error("CanvasEngineActivation subclasses must implement getEngine()");
  }

  setEngine(_engine) {
    throw new Error("CanvasEngineActivation subclasses must implement setEngine()");
  }

  setUsing(_using) {
    throw new Error("CanvasEngineActivation subclasses must implement setUsing()");
  }

  markAttempted() {
    throw new Error("CanvasEngineActivation subclasses must implement markAttempted()");
  }

  loadOptions(resumeTime) {
    return { startTime: resumeTime };
  }

  bindEngineEvents(_engine, _sessionId) {}

  async activate(request) {
    const { sessionId, url } = request;

    if (this.resetsNativePlaybackEvents) this.host.setNativePlaybackEventsSuppressed(false);
    this.host.disablePiPForCanvasPlayback();
    this.logger.info(`Playing with ${this.label}, url:`, url);
    this.markAttempted();
    this.host.reportLifecycle("player_engine_selected", { engine: this.id });

    const resumeTime = this.host.takeResumeTime();
    const isCurrent = () => this.host.isSessionCurrent(sessionId);

    try {
      const module = await this.loadModule();
      if (!isCurrent()) return false;

      const engine = this.deps.createPlaybackEngineAdapter({
        id: this.id,
        engine: this.createWrapper(module),
      });
      this.setEngine(engine);
      this.host.trackManagedEngine(this.id, engine);
      this.bindEngineEvents(engine, sessionId);

      await engine.load(url, this.loadOptions(resumeTime));
      if (!isCurrent()) {
        await engine.destroy().catch(() => {});
        if (this.getEngine() === engine) this.setEngine(null);
        return false;
      }

      this.setUsing(true);
      this.host.getPresentation()?.hideLoading();

      // The wrapper already attached the source, so align the position and
      // start playback the way the native path does. Any error throws and
      // falls through to the AVPlayer fallback.
      if (resumeTime > 0) {
        try {
          await engine.seek(resumeTime);
        } catch (seekError) {
          this.logger.warn(
            `[${this.logTag}] seek-on-load failed, will try after play()`,
            seekError,
          );
        }
      }
      await engine.play();
      if (this.notifiesStartAfterPlay) this.host.handlePlaybackStarted();
      this.host.markPlaying();
      return true;
    } catch (error) {
      this.host.setPlaybackSystemState("none");
      this.logger.warn(`[${this.logTag}] init failed, falling back to AVPlayer:`, error);
      this.host.recordPlaybackError();
      this.host.reportLifecycle("player_engine_fallback", {
        from: this.id,
        to: ENGINE_ID.AVPLAYER,
        reason: error?.message || String(error),
      });
      try {
        await this.getEngine()?.destroy?.();
      } catch {
        // best effort
      }
      this.setEngine(null);
      this.setUsing(false);
      if (isCurrent()) {
        this.host.tryAVPlayerFallback();
      }
      return false;
    }
  }
}
