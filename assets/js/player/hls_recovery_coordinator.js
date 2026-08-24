import { runGuardedPlaybackRetry, scheduleGuardedPlaybackRetry } from "./playback_load_guard.js";

export const HLS_RECOVERY_OUTCOME = Object.freeze({
  IGNORED: "ignored",
  REFRESH_TOKEN: "refresh_token",
  RECOVERY_RUNNING: "recovery_running",
  RECOVERY_SCHEDULED: "recovery_scheduled",
  FALLBACK_REQUIRED: "fallback_required",
});

export const HLS_RECOVERY_OPERATION = Object.freeze({
  SOFT_RELOAD: "soft_reload",
  START_LOAD: "start_load",
  RECOVER_MEDIA: "recover_media",
});

export const HLS_RECOVERY_REASON = Object.freeze({
  NON_FATAL: "non_fatal",
  AUTHORIZATION: "authorization",
  MANIFEST_SOFT_RELOAD: "manifest_soft_reload",
  MANIFEST_UNAVAILABLE: "manifest_unavailable",
  NETWORK_RESTART: "network_restart",
  NETWORK_SOFT_RELOAD: "network_soft_reload",
  MEDIA_RECOVERY: "media_recovery",
  MEDIA_SOFT_RELOAD: "media_soft_reload",
  UNHANDLED_FATAL: "unhandled_fatal",
});

export const DEFAULT_HLS_RECOVERY_LIMITS = Object.freeze({
  manifestSoftReloads: 2,
  networkRestarts: 3,
  mediaRecoveries: 2,
  manifestRetryBaseDelayMs: 1_000,
});

const AUTHORIZATION_CODES = new Set([401, 403]);
const MANIFEST_ERROR_DETAILS = new Set(["manifestLoadError", "manifestParsingError"]);

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`HLS recovery ${name} boundary must be a function`);
  }
  return value;
}

function safeCall(callback, ...args) {
  if (!callback) return;

  try {
    callback(...args);
  } catch {
    // Diagnostics must never become a playback failure source.
  }
}

function normalizeAttempts(value) {
  const attempts = Number(value);
  return Number.isInteger(attempts) && attempts >= 0 ? attempts : 0;
}

function normalizeCode(value) {
  const code = Number(value);
  return Number.isInteger(code) && code > 0 ? code : null;
}

function normalizeText(value, fallback) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function normalizeLimits(limits = {}) {
  const normalized = {
    ...DEFAULT_HLS_RECOVERY_LIMITS,
    ...limits,
  };

  for (const key of [
    "manifestSoftReloads",
    "networkRestarts",
    "mediaRecoveries",
    "manifestRetryBaseDelayMs",
  ]) {
    const value = Number(normalized[key]);
    if (!Number.isInteger(value) || value < 0) {
      throw new TypeError(`HLS recovery limit ${key} must be a non-negative integer`);
    }
    normalized[key] = value;
  }

  return Object.freeze(normalized);
}

export function normalizeHlsRecoveryEvent(data = {}) {
  return Object.freeze({
    fatal: data?.fatal === true,
    type: normalizeText(data?.type, "unknown"),
    details: normalizeText(data?.details, "unknown"),
    responseCode: normalizeCode(data?.response?.code),
  });
}

function decision(event, options) {
  return Object.freeze({
    event,
    outcome: options.outcome,
    operation: options.operation ?? null,
    reason: options.reason,
    previousAttempts: options.previousAttempts,
    nextAttempts: options.nextAttempts,
    delayMs: options.delayMs ?? 0,
  });
}

export function classifyHlsRecovery(
  data,
  { attempts = 0, canSoftReload = false, limits = DEFAULT_HLS_RECOVERY_LIMITS } = {},
) {
  const event = normalizeHlsRecoveryEvent(data);
  const previousAttempts = normalizeAttempts(attempts);
  const normalizedLimits = normalizeLimits(limits);

  if (!event.fatal) {
    return decision(event, {
      outcome: HLS_RECOVERY_OUTCOME.IGNORED,
      reason: HLS_RECOVERY_REASON.NON_FATAL,
      previousAttempts,
      nextAttempts: previousAttempts,
    });
  }

  if (AUTHORIZATION_CODES.has(event.responseCode)) {
    return decision(event, {
      outcome: HLS_RECOVERY_OUTCOME.REFRESH_TOKEN,
      reason: HLS_RECOVERY_REASON.AUTHORIZATION,
      previousAttempts,
      nextAttempts: previousAttempts,
    });
  }

  if (event.type === "networkError") {
    if (MANIFEST_ERROR_DETAILS.has(event.details)) {
      if (canSoftReload && previousAttempts < normalizedLimits.manifestSoftReloads) {
        const nextAttempts = previousAttempts + 1;

        return decision(event, {
          outcome: HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED,
          operation: HLS_RECOVERY_OPERATION.SOFT_RELOAD,
          reason: HLS_RECOVERY_REASON.MANIFEST_SOFT_RELOAD,
          previousAttempts,
          nextAttempts,
          delayMs: normalizedLimits.manifestRetryBaseDelayMs * nextAttempts,
        });
      }

      return decision(event, {
        outcome: HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED,
        reason: HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE,
        previousAttempts,
        nextAttempts: previousAttempts,
      });
    }

    if (previousAttempts < normalizedLimits.networkRestarts) {
      return decision(event, {
        outcome: HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING,
        operation: HLS_RECOVERY_OPERATION.START_LOAD,
        reason: HLS_RECOVERY_REASON.NETWORK_RESTART,
        previousAttempts,
        nextAttempts: previousAttempts + 1,
      });
    }

    return decision(event, {
      outcome: HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING,
      operation: HLS_RECOVERY_OPERATION.SOFT_RELOAD,
      reason: HLS_RECOVERY_REASON.NETWORK_SOFT_RELOAD,
      previousAttempts,
      nextAttempts: 0,
    });
  }

  if (event.type === "mediaError") {
    if (previousAttempts < normalizedLimits.mediaRecoveries) {
      return decision(event, {
        outcome: HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING,
        operation: HLS_RECOVERY_OPERATION.RECOVER_MEDIA,
        reason: HLS_RECOVERY_REASON.MEDIA_RECOVERY,
        previousAttempts,
        nextAttempts: previousAttempts + 1,
      });
    }

    return decision(event, {
      outcome: HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING,
      operation: HLS_RECOVERY_OPERATION.SOFT_RELOAD,
      reason: HLS_RECOVERY_REASON.MEDIA_SOFT_RELOAD,
      previousAttempts,
      nextAttempts: 0,
    });
  }

  return decision(event, {
    outcome: HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED,
    reason: HLS_RECOVERY_REASON.UNHANDLED_FATAL,
    previousAttempts,
    nextAttempts: previousAttempts,
  });
}

function canSoftReload(loader) {
  try {
    return loader?.canSoftReload?.("hls") === true;
  } catch {
    return false;
  }
}

function invokeLoader(loader, method, args = []) {
  if (!loader || typeof loader[method] !== "function") {
    throw new TypeError(`HLS recovery loader is missing ${method}()`);
  }
  return loader[method](...args);
}

function operationFor(decisionValue, loader, url) {
  switch (decisionValue.operation) {
    case HLS_RECOVERY_OPERATION.SOFT_RELOAD:
      return () => invokeLoader(loader, "loadHlsSoft", [url]);
    case HLS_RECOVERY_OPERATION.START_LOAD:
      return () => invokeLoader(loader, "startLoad");
    case HLS_RECOVERY_OPERATION.RECOVER_MEDIA:
      return () => invokeLoader(loader, "recoverMediaError");
    default:
      throw new TypeError(`Unknown HLS recovery operation: ${String(decisionValue.operation)}`);
  }
}

function result(decisionValue, { promise = null, timer = null } = {}) {
  return Object.freeze({
    decision: decisionValue,
    promise,
    timer,
  });
}

export class HlsRecoveryCoordinator {
  constructor({
    limits = DEFAULT_HLS_RECOVERY_LIMITS,
    onFailure = null,
    onRecovering = null,
    runRetry = runGuardedPlaybackRetry,
    scheduleRetry = scheduleGuardedPlaybackRetry,
    schedule = (callback, delayMs) => setTimeout(callback, delayMs),
    cancelSchedule = (timer) => clearTimeout(timer),
  } = {}) {
    this.limits = normalizeLimits(limits);
    this.onFailure = optionalCallback(onFailure, "onFailure");
    this.onRecovering = optionalCallback(onRecovering, "onRecovering");
    this.runRetry = optionalCallback(runRetry, "runRetry");
    this.scheduleRetry = optionalCallback(scheduleRetry, "scheduleRetry");
    this.schedule = optionalCallback(schedule, "schedule");
    this.cancelSchedule = optionalCallback(cancelSchedule, "cancelSchedule");
    this.attempts = 0;
    this.timer = null;
    this.activePromise = null;
    this.lastDecision = null;
    this.destroyed = false;
  }

  handle(data, { loader, url, isCurrent } = {}) {
    this.assertActive();

    if (typeof isCurrent !== "function") {
      throw new TypeError("HLS recovery requires an isCurrent() guard");
    }

    const nextDecision = classifyHlsRecovery(data, {
      attempts: this.attempts,
      canSoftReload: canSoftReload(loader),
      limits: this.limits,
    });

    this.lastDecision = nextDecision;

    if (
      nextDecision.outcome !== HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING &&
      nextDecision.outcome !== HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED
    ) {
      return result(nextDecision);
    }

    this.attempts = nextDecision.nextAttempts;
    safeCall(this.onRecovering, nextDecision);

    const run = operationFor(nextDecision, loader, url);
    const onError = (error) => safeCall(this.onFailure, error, nextDecision);

    if (nextDecision.outcome === HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED) {
      this.cancelScheduledRecovery();

      const timer = this.scheduleRetry({
        delayMs: nextDecision.delayMs,
        isCurrent,
        onError,
        run,
        schedule: (callback, delayMs) =>
          this.schedule(() => {
            this.timer = null;
            callback();
          }, delayMs),
      });

      this.timer = timer;
      return result(nextDecision, { timer });
    }

    const operationPromise = this.runRetry({ isCurrent, onError, run });
    const trackedPromise = Promise.resolve(operationPromise).finally(() => {
      if (this.activePromise === trackedPromise) this.activePromise = null;
    });

    this.activePromise = trackedPromise;
    return result(nextDecision, { promise: trackedPromise });
  }

  markRecovered() {
    this.cancelScheduledRecovery();
    this.attempts = 0;
    this.lastDecision = null;
  }

  reset() {
    this.markRecovered();
  }

  cancel() {
    this.cancelScheduledRecovery();
    this.attempts = 0;
    this.lastDecision = null;
  }

  snapshot() {
    return Object.freeze({
      attempts: this.attempts,
      scheduled: this.timer != null,
      recovering: this.activePromise != null,
      destroyed: this.destroyed,
      lastDecision: this.lastDecision,
    });
  }

  destroy() {
    if (this.destroyed) return false;
    this.cancel();
    this.destroyed = true;
    return true;
  }

  cancelScheduledRecovery() {
    if (this.timer == null) return false;
    this.cancelSchedule(this.timer);
    this.timer = null;
    return true;
  }

  assertActive() {
    if (this.destroyed) {
      throw new Error("HLS recovery coordinator has been destroyed");
    }
  }
}

export function createHlsRecoveryCoordinator(options = {}) {
  return new HlsRecoveryCoordinator(options);
}
