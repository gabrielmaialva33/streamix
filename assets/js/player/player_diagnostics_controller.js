import { playerLogger as defaultLogger } from "../core/logger.js";
import { diagnoseError } from "./player_diagnostics.js";
import { collectStartupDiagnostics } from "./startup_diagnostics.js";

const REDACTED = "[redacted]";
const REDACTED_URL = "[redacted-url]";
const TRUNCATED = "[truncated]";
const CIRCULAR = "[circular]";
const MAX_DEPTH = 4;
const MAX_ARRAY_LENGTH = 25;
const MAX_STRING_LENGTH = 500;
const URL_PATTERN = /\b(?:https?|wss?):\/\/[^\s"'<>]+/giu;
const SENSITIVE_SUFFIXES = [
  "api_key",
  "authorization",
  "cookie",
  "credential",
  "password",
  "secret",
  "token",
  "uri",
  "url",
];

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

function isSensitiveKey(key) {
  const normalized = String(key ?? "").toLowerCase();

  return SENSITIVE_SUFFIXES.some(
    (suffix) => normalized === suffix || normalized.endsWith(`_${suffix}`),
  );
}

function sanitizeString(value) {
  const redacted = value.replace(URL_PATTERN, REDACTED_URL);

  if (redacted.length <= MAX_STRING_LENGTH) return redacted;
  return `${redacted.slice(0, MAX_STRING_LENGTH)}…`;
}

function sanitizeValue(value, key, depth, seen) {
  if (value === null || value === undefined) return value;
  if (isSensitiveKey(key)) return REDACTED;

  if (typeof value === "string") return sanitizeString(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "function" || typeof value === "symbol") return undefined;

  if (value instanceof Error) {
    return {
      name: sanitizeString(value.name || "Error"),
      message: sanitizeString(value.message || ""),
    };
  }

  if (value instanceof Date) return value.toISOString();
  if (depth >= MAX_DEPTH) return TRUNCATED;
  if (seen.has(value)) return CIRCULAR;

  seen.add(value);

  if (Array.isArray(value)) {
    const sanitized = value
      .slice(0, MAX_ARRAY_LENGTH)
      .map((entry) => sanitizeValue(entry, "", depth + 1, seen));
    seen.delete(value);
    return sanitized;
  }

  const sanitized = {};
  for (const [entryKey, entryValue] of Object.entries(value)) {
    const normalized = sanitizeValue(entryValue, entryKey, depth + 1, seen);
    if (normalized !== undefined) sanitized[entryKey] = normalized;
  }

  seen.delete(value);
  return sanitized;
}

export function sanitizeDiagnosticPayload(payload) {
  if (!payload || typeof payload !== "object") return {};
  return sanitizeValue(payload, "", 0, new WeakSet());
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
    this.showPlaybackError(message);

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
