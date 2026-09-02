import {
  CANVAS_ENGINE_ACTIVATION_HOST_METHODS,
  CanvasEngineActivation,
} from "./canvas_engine_activation.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import { loadH265web } from "./playback_module_loader.js";
import { createPlaybackTickThrottle } from "./playback_tick_throttle.js";

export const H265WEB_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...CANVAS_ENGINE_ACTIVATION_HOST_METHODS,
  "getH265web",
  "getH265webBaseUrl",
  "getH265webMount",
  "markH265webAttempted",
  "setH265web",
  "setUsingH265web",
]);

/**
 * h265web renders into its own canvas inside an opaque mount. The template
 * ships `<div id="h265web-mount" phx-update="ignore">` so a LiveView patch
 * does not wipe the canvas mid-playback. Playback events come from the
 * wrapper itself, so they are mirrored here instead of through `<video>`.
 */
export class H265webEngineActivation extends CanvasEngineActivation {
  constructor({ dependencies = {}, host, logger } = {}) {
    super({
      dependencies: { createPlaybackTickThrottle, loadH265web, ...dependencies },
      host,
      hostMethods: H265WEB_ENGINE_ACTIVATION_HOST_METHODS,
      logger,
      name: "H265webEngineActivation",
    });
  }

  get id() {
    return ENGINE_ID.H265WEB;
  }

  get selection() {
    return ENGINE_SELECTION.H265WEB;
  }

  get label() {
    return "h265web";
  }

  get logTag() {
    return "H265web";
  }

  loadModule() {
    return this.deps.loadH265web();
  }

  createWrapper({ H265webWrapper }) {
    const mountEl = this.host.getH265webMount();
    if (!mountEl) {
      throw new Error("h265web mount element (#h265web-mount) not found in template");
    }

    return new H265webWrapper({
      video: this.host.getVideo(),
      mountEl,
      // Override base URL via `data-h265web-base-url` on the player container,
      // useful when the SDK is served from another origin (CDN, edge cache).
      baseUrl: this.host.getH265webBaseUrl() || undefined,
    });
  }

  getEngine() {
    return this.host.getH265web();
  }

  setEngine(engine) {
    this.host.setH265web(engine);
  }

  setUsing(using) {
    this.host.setUsingH265web(using);
  }

  markAttempted() {
    this.host.markH265webAttempted();
  }

  loadOptions(resumeTime) {
    return { startTime: resumeTime, autoPlay: true };
  }

  bindEngineEvents(engine, sessionId) {
    const ticks = this.deps.createPlaybackTickThrottle();
    const isActive = () => this.host.isSessionCurrent(sessionId) && this.getEngine() === engine;

    engine.on("playing", () => {
      if (!isActive()) return;
      this.host.getPresentation()?.updatePlayPauseUI(false);
      this.host.handlePlaybackStarted();
      this.host.emitPlaybackEvent("play");
    });
    engine.on("paused", () => {
      if (!isActive()) return;
      this.host.getPresentation()?.updatePlayPauseUI(true);
      this.host.handlePlaybackPaused();
      this.host.emitPlaybackEvent("pause");
    });
    engine.on("timeupdate", () => {
      if (!isActive()) return;

      const tick = ticks.next();
      if (tick.updateUi) this.host.updateTimeUI();
      if (tick.reportProgress && this.host.getContentType() === "vod") this.host.reportProgress();
    });
    engine.on("ended", () => {
      if (!isActive()) return;
      this.host.getPresentation()?.updatePlayPauseUI(true);
      this.host.handlePlaybackEnded();
      this.host.flushPlaybackMetrics("completed");
    });
  }
}

export function createH265webEngineActivation(options) {
  return new H265webEngineActivation(options);
}
