import { classifyMpegtsError, executeMpegtsDecision } from "./mpegts_error_policy.js";

export const DEFAULT_MPEGTS_RECOVERY_LIMITS = Object.freeze({
  networkAttempts: 3,
  recreateAttempts: 1,
});

const PASSIVE_ACTIONS = new Set(["ignore", "refresh-token"]);

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`MPEG-TS recovery ${name} boundary must be a function`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  return requiredCallback(value, name);
}

function safeCall(callback, ...args) {
  if (!callback) return;

  try {
    callback(...args);
  } catch {
    // Diagnostics must never become a playback failure source.
  }
}

function normalizeLimit(value, fallback, name) {
  const limit = Number(value ?? fallback);

  if (!Number.isInteger(limit) || limit < 0) {
    throw new TypeError(`MPEG-TS recovery ${name} must be a non-negative integer`);
  }

  return limit;
}

function normalizeSessionId(value) {
  if (value == null) return null;

  const sessionId = Number(value);
  if (!Number.isInteger(sessionId) || sessionId < 0) {
    throw new TypeError("MPEG-TS recovery sessionId must be a non-negative integer");
  }

  return sessionId;
}

function callbackOrDefault(value, fallback, name) {
  return value == null ? fallback : requiredCallback(value, name);
}

function shouldReportRecovering(decision) {
  return !PASSIVE_ACTIONS.has(decision?.action);
}

/**
 * Owns MPEG-TS retry state without knowing how the product switches engines.
 *
 * The coordinator classifies transport errors, tracks bounded retry budgets,
 * deduplicates concurrent recovery for one playback session, and owns delayed
 * retry cancellation. The VideoPlayer supplies callbacks for direct retry,
 * MPEG-TS recreation, and cross-engine fallback.
 */
export class MpegtsRecoveryCoordinator {
  constructor({
    maxNetworkAttempts = DEFAULT_MPEGTS_RECOVERY_LIMITS.networkAttempts,
    maxRecreateAttempts = DEFAULT_MPEGTS_RECOVERY_LIMITS.recreateAttempts,
    classify = classifyMpegtsError,
    execute = executeMpegtsDecision,
    schedule = (callback, delayMs) => globalThis.setTimeout(callback, delayMs),
    cancelSchedule = (timer) => globalThis.clearTimeout(timer),
    onDecision = null,
    onRecovering = null,
    onFailure = null,
  } = {}) {
    this.maxNetworkAttempts = normalizeLimit(
      maxNetworkAttempts,
      DEFAULT_MPEGTS_RECOVERY_LIMITS.networkAttempts,
      "maxNetworkAttempts",
    );
    this.maxRecreateAttempts = normalizeLimit(
      maxRecreateAttempts,
      DEFAULT_MPEGTS_RECOVERY_LIMITS.recreateAttempts,
      "maxRecreateAttempts",
    );
    this.classify = requiredCallback(classify, "classify");
    this.execute = requiredCallback(execute, "execute");
    this.schedule = requiredCallback(schedule, "schedule");
    this.cancelSchedule = requiredCallback(cancelSchedule, "cancelSchedule");
    this.onDecision = optionalCallback(onDecision, "onDecision");
    this.onRecovering = optionalCallback(onRecovering, "onRecovering");
    this.onFailure = optionalCallback(onFailure, "onFailure");

    this.networkAttempts = 0;
    this.recreateAttempts = 0;
    this.activeSessionId = null;
    this.activePromise = null;
    this.retryTimer = null;
    this.scheduledResolve = null;
    this.destroyed = false;
  }

  handle(errorData = {}, context = {}) {
    this.assertActive();

    const sessionId = normalizeSessionId(context.sessionId);
    if (this.activePromise && this.activeSessionId === sessionId) {
      return this.activePromise;
    }

    const isCurrent = callbackOrDefault(context.isCurrent, () => true, "isCurrent");
    const decision = this.classify(errorData, {
      canTryAVPlayer: context.canTryAVPlayer === true,
      canTryDirect: context.canTryDirect === true,
      maxNetworkAttempts: this.maxNetworkAttempts,
      maxRecreateAttempts: this.maxRecreateAttempts,
      networkAttempts: this.networkAttempts,
      recreateAttempts: this.recreateAttempts,
    });

    this.recordCounter(decision?.counter);
    safeCall(this.onDecision, decision, errorData, this.snapshot());

    if (shouldReportRecovering(decision)) {
      safeCall(this.onRecovering, decision, errorData, this.snapshot());
    }

    const onFailure = optionalCallback(context.onFailure, "onFailure") ?? this.onFailure;

    const execution = Promise.resolve()
      .then(() =>
        this.execute(decision, {
          cleanup: context.cleanup,
          fallbackAVPlayer: () => context.fallbackAVPlayer?.(decision),
          fallbackNative: () => context.fallbackNative?.(decision),
          isCurrent,
          refreshToken: () => context.refreshToken?.(decision),
          retryDirect: () => {
            this.resetAttempts();
            return context.retryDirect?.(decision);
          },
          retryMpegts: () => context.retryMpegts?.(decision),
          schedule: (callback, delayMs) => this.scheduleRecovery(callback, delayMs, isCurrent),
        }),
      )
      .catch((error) => {
        safeCall(onFailure, error, decision, {
          sessionId,
          snapshot: this.snapshot(),
        });
        return false;
      });

    const tracked = execution.finally(() => {
      if (this.activePromise === tracked && this.activeSessionId === sessionId) {
        this.activePromise = null;
        this.activeSessionId = null;
      }
    });

    this.activeSessionId = sessionId;
    this.activePromise = tracked;
    return tracked;
  }

  markRecovered() {
    this.reset();
  }

  reset() {
    this.cancelScheduledRecovery();
    this.resetAttempts();
  }

  cancel() {
    this.cancelScheduledRecovery();
  }

  snapshot() {
    return Object.freeze({
      networkAttempts: this.networkAttempts,
      recreateAttempts: this.recreateAttempts,
      activeSessionId: this.activeSessionId,
      recoveryActive: this.activePromise != null,
      retryScheduled: this.retryTimer != null,
      destroyed: this.destroyed,
    });
  }

  destroy() {
    if (this.destroyed) return false;

    this.destroyed = true;
    this.cancelScheduledRecovery();
    this.activeSessionId = null;
    this.activePromise = null;
    return true;
  }

  recordCounter(counter) {
    if (counter === "network") this.networkAttempts += 1;
    if (counter === "recreate") this.recreateAttempts += 1;
  }

  resetAttempts() {
    this.networkAttempts = 0;
    this.recreateAttempts = 0;
  }

  scheduleRecovery(callback, delayMs, isCurrent) {
    this.cancelScheduledRecovery();

    const delay = Math.max(0, Number(delayMs) || 0);
    if (delay === 0) return callback();

    return new Promise((resolve, reject) => {
      this.scheduledResolve = resolve;

      const run = async () => {
        this.retryTimer = null;
        this.scheduledResolve = null;

        if (!isCurrent()) {
          resolve(false);
          return;
        }

        try {
          resolve(await callback());
        } catch (error) {
          reject(error);
        }
      };

      try {
        this.retryTimer = this.schedule(run, delay);
      } catch (error) {
        this.scheduledResolve = null;
        reject(error);
      }
    });
  }

  cancelScheduledRecovery() {
    if (this.retryTimer != null) {
      this.cancelSchedule(this.retryTimer);
      this.retryTimer = null;
    }

    if (this.scheduledResolve) {
      const resolve = this.scheduledResolve;
      this.scheduledResolve = null;
      resolve(false);
    }
  }

  assertActive() {
    if (this.destroyed) {
      throw new Error("MPEG-TS recovery coordinator has been destroyed");
    }
  }
}

export function createMpegtsRecoveryCoordinator(options = {}) {
  return new MpegtsRecoveryCoordinator(options);
}
