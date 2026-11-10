import { sanitizeDiagnosticPayload } from "../core/diagnostic_payload.js";
import { playerLogger as defaultLogger } from "../core/logger.js";
import { diagnoseError } from "./player_diagnostics.js";
import { collectStartupDiagnostics } from "./startup_diagnostics.js";

export { sanitizeDiagnosticPayload } from "../core/diagnostic_payload.js";

function requiredCallback(name, value) {
  if (typeof value !== "function") {
    throw new TypeError(`${name} must be a function`);
  }

  return value;
}

function optionalCallback(value) {
  return typeof value === "function" ? value : () => {};
}

function loggerCallback(logger, method) {
  const callback = logger?.[method];
  return typeof callback === "function" ? callback.bind(logger) : () => {};
}

function normalizeLogger(logger) {
  return {
    debug: loggerCallback(logger, "debug"),
    warn: loggerCallback(logger, "warn"),
  };
}

export class PlayerDiagnosticsController {
  constructor({
    collectStartup = collectStartupDiagnostics,
    diagnose = diagnoseError,
    getDebugContext = () => ({}),
    getErrorContext = () => ({}),
    getResourcePolicy = () => ({}),
    initCodecAwareABR,
    logger = defaultLogger,
    pushEvent,
    showPlaybackError,
  } = {}) {
    this.collectStartup = requiredCallback("collectStartup", collectStartup);
    this.diagnose = requiredCallback("diagnose", diagnose);
    this.getDebugContext = requiredCallback("getDebugContext", getDebugContext);
    this.getErrorContext = requiredCallback("getErrorContext", getErrorContext);
    this.getResourcePolicy = requiredCallback("getResourcePolicy", getResourcePolicy);
    this.initCodecAwareABR = optionalCallback(initCodecAwareABR);
    this.logger = normalizeLogger(logger);
    this.pushEvent = requiredCallback("pushEvent", pushEvent);
    this.showPlaybackError = requiredCallback("showPlaybackError", showPlaybackError);
  }

  async runStartup() {
    try {
      const policy = this.getResourcePolicy();
      const diagnostics = await this.collectStartup({ policy });
      this.emit("device_diagnostics", diagnostics);

      const recommendation = diagnostics?.advanced?.codecRecommendation;
      if (recommendation) this.initCodecAwareABR(recommendation);

      return diagnostics;
    } catch (error) {
      this.logger.debug("[VideoPlayer] Startup diagnostics failed (non-critical)", error);
      return null;
    }
  }

  async showError(message, error = null, runDiagnostics = false) {
    this.showPlaybackError(
      message,
      null,
      error?.type === "network" ? "network_error" : "fatal_media_error",
    );

    if (!runDiagnostics || !error) return null;

    try {
      const diagnosis = await this.diagnose(error, this.getErrorContext());
      this.logger.debug("[VideoPlayer] Diagnostics result:", diagnosis);

      if (diagnosis?.suggestedPlayer?.player && diagnosis.suggestedPlayer.player !== "native") {
        this.emit("diagnostic_suggestion", {
          player: diagnosis.suggestedPlayer.player,
          reason: diagnosis.suggestedPlayer.reason,
          recommendations: diagnosis.recommendations,
        });
      }

      return diagnosis;
    } catch (diagnosticError) {
      this.logger.warn("[VideoPlayer] Diagnostics failed:", diagnosticError);
      return null;
    }
  }

  reportDebug(stage, extra = {}) {
    try {
      const payload = sanitizeDiagnosticPayload({
        stage,
        ...this.getDebugContext(),
        ...extra,
      });

      this.emit("player_debug", payload);
      return payload;
    } catch (error) {
      this.logger.debug("[VideoPlayer] Debug report failed:", error);
      return null;
    }
  }

  emit(event, payload) {
    try {
      this.pushEvent(event, sanitizeDiagnosticPayload(payload));
      return true;
    } catch (error) {
      this.logger.debug(`[VideoPlayer] Failed to emit ${event}:`, error);
      return false;
    }
  }
}

export function createPlayerDiagnosticsController(options) {
  return new PlayerDiagnosticsController(options);
}
