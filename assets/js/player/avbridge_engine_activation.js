import {
  CANVAS_ENGINE_ACTIVATION_HOST_METHODS,
  CanvasEngineActivation,
} from "./canvas_engine_activation.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import { loadAvbridge } from "./playback_module_loader.js";

export const AVBRIDGE_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...CANVAS_ENGINE_ACTIVATION_HOST_METHODS,
  "getAvbridge",
  "markAvbridgeAttempted",
  "setAvbridge",
  "setUsingAvbridge",
]);

/**
 * WebCodecs-backed avbridge engine for UHD HEVC. Renders into the shared
 * `<video>` element, so native playback events are re-enabled before start.
 */
export class AvbridgeEngineActivation extends CanvasEngineActivation {
  constructor({ dependencies = {}, host, logger } = {}) {
    super({
      dependencies: { loadAvbridge, ...dependencies },
      host,
      hostMethods: AVBRIDGE_ENGINE_ACTIVATION_HOST_METHODS,
      logger,
      name: "AvbridgeEngineActivation",
    });
  }

  get id() {
    return ENGINE_ID.AVBRIDGE;
  }

  get selection() {
    return ENGINE_SELECTION.AVBRIDGE;
  }

  get label() {
    return "avbridge";
  }

  get logTag() {
    return "Avbridge";
  }

  get resetsNativePlaybackEvents() {
    return true;
  }

  get notifiesStartAfterPlay() {
    return true;
  }

  loadModule() {
    return this.deps.loadAvbridge();
  }

  createWrapper({ AvbridgeWrapper }) {
    return new AvbridgeWrapper({ video: this.host.getVideo() });
  }

  getEngine() {
    return this.host.getAvbridge();
  }

  setEngine(engine) {
    this.host.setAvbridge(engine);
  }

  setUsing(using) {
    this.host.setUsingAvbridge(using);
  }

  markAttempted() {
    this.host.markAvbridgeAttempted();
  }
}

export function createAvbridgeEngineActivation(options) {
  return new AvbridgeEngineActivation(options);
}
