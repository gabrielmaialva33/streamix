import {
  driftChanged,
  normalizeDriftMs,
  renderSyncStatus,
  resolveSyncStatus,
  syncStatusText,
} from "./sync_status.js";

export const SYNC_STATUS_ELEMENT_ID = "watch-party-sync-status";

function requiredFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`SyncStatusPublisher requires ${name}()`);
  }
  return value;
}

/**
 * Owns the published sync status: precedence resolution, drift throttling,
 * badge rendering and the deduplicated `wp_sync_status` push. The hook only
 * supplies the current hold context and the transport.
 */
export class SyncStatusPublisher {
  constructor({
    documentRef = globalThis.document,
    elementId = SYNC_STATUS_ELEMENT_ID,
    getContext,
    push,
    render = null,
  } = {}) {
    this.documentRef = documentRef;
    this.elementId = elementId;
    this.getContext = requiredFunction(getContext, "getContext");
    this.push = requiredFunction(push, "push");
    this.renderOverride = render == null ? null : requiredFunction(render, "render");
    this.lastStatus = null;
    this.lastDrift = null;
  }

  publish(status, driftMs = null) {
    const { holdReason = null, isHost = false } = this.getContext();
    const resolved = resolveSyncStatus({ holdReason, isHost, status });
    const drift = normalizeDriftMs(driftMs);

    this.render(resolved, drift);
    if (resolved === this.lastStatus && !driftChanged(this.lastDrift, drift)) return false;

    this.lastStatus = resolved;
    this.lastDrift = drift;
    this.push("wp_sync_status", { status: resolved, drift_ms: drift });
    return true;
  }

  render(status, driftMs = null) {
    if (this.renderOverride) return this.renderOverride(status, driftMs);
    return this.renderBadge(status, driftMs);
  }

  renderBadge(status, driftMs = null) {
    const element = this.documentRef?.getElementById?.(this.elementId) ?? null;
    const { isHost = false } = this.getContext();
    return renderSyncStatus(element, { driftMs, isHost, status });
  }

  rerender() {
    if (!this.lastStatus) return false;
    return this.render(this.lastStatus, this.lastDrift);
  }

  text(status, driftMs = null) {
    const { isHost = false } = this.getContext();
    return syncStatusText({ driftMs, isHost, status });
  }

  snapshot() {
    return Object.freeze({ drift: this.lastDrift, status: this.lastStatus });
  }
}

export function createSyncStatusPublisher(options) {
  return new SyncStatusPublisher(options);
}
