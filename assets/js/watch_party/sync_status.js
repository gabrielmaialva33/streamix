export const SYNC_STATUS = Object.freeze({
  BUFFERING: "buffering",
  CONNECTING: "connecting",
  CORRECTING: "correcting",
  DISCONNECTED: "disconnected",
  HOST_OFFLINE: "host_offline",
  SYNCED: "synced",
});

export const DRIFT_PUBLISH_STEP_MS = 100;

const HOLD_STATUS_BY_REASON = Object.freeze({
  buffering: SYNC_STATUS.BUFFERING,
  connecting: SYNC_STATUS.CONNECTING,
  disconnected: SYNC_STATUS.DISCONNECTED,
  host_offline: SYNC_STATUS.HOST_OFFLINE,
});

const STATUS_CLASSES = Object.freeze([
  "bg-warning/90",
  "bg-error/90",
  "bg-brand/90",
  "bg-success/90",
  "text-black",
  "text-white",
]);

const WARNING_STATUSES = new Set([
  SYNC_STATUS.HOST_OFFLINE,
  SYNC_STATUS.CONNECTING,
  SYNC_STATUS.CORRECTING,
  SYNC_STATUS.BUFFERING,
]);

/**
 * A durable hold reason outranks any momentary status; hosts only ever show
 * buffering, disconnected or synced.
 */
export function resolveSyncStatus({ holdReason = null, isHost = false, status }) {
  let resolved = status;
  if (!isHost && holdReason && HOLD_STATUS_BY_REASON[holdReason]) {
    resolved = HOLD_STATUS_BY_REASON[holdReason];
  }
  if (isHost && resolved !== SYNC_STATUS.BUFFERING && resolved !== SYNC_STATUS.DISCONNECTED) {
    resolved = SYNC_STATUS.SYNCED;
  }
  return resolved;
}

export function normalizeDriftMs(driftMs) {
  const numeric = Number(driftMs);
  if (driftMs === null || driftMs === undefined || !Number.isFinite(numeric)) return null;
  return Math.max(0, Math.round(numeric));
}

export function driftChanged(previous, next) {
  return next !== null && (previous === null || Math.abs(next - previous) >= DRIFT_PUBLISH_STEP_MS);
}

export function syncStatusText({ driftMs = null, isHost = false, status }) {
  if (isHost) {
    if (status === SYNC_STATUS.BUFFERING) return "Aguardando o buffer";
    if (status === SYNC_STATUS.DISCONNECTED) return "Sincronização desconectada";
    return "Você controla a reprodução";
  }

  switch (status) {
    case SYNC_STATUS.HOST_OFFLINE:
      return "Anfitrião desconectado — aguardando retorno";
    case SYNC_STATUS.CONNECTING:
      return "Conectando à sincronização";
    case SYNC_STATUS.CORRECTING:
      return Number.isInteger(driftMs) && driftMs > 0
        ? `Ajustando sincronização (${driftMs} ms)`
        : "Ajustando sincronização";
    case SYNC_STATUS.BUFFERING:
      return "Aguardando o buffer";
    case SYNC_STATUS.DISCONNECTED:
      return "Sincronização desconectada";
    default:
      return Number.isInteger(driftMs) && driftMs >= DRIFT_PUBLISH_STEP_MS
        ? `Sincronizado com o anfitrião (${driftMs} ms)`
        : "Sincronizado com o anfitrião";
  }
}

export function syncStatusClasses({ isHost = false, status }) {
  if (status === SYNC_STATUS.DISCONNECTED) return ["bg-error/90", "text-white"];
  if (WARNING_STATUSES.has(status)) return ["bg-warning/90", "text-black"];
  if (isHost) return ["bg-brand/90", "text-white"];
  return ["bg-success/90", "text-black"];
}

/**
 * Applies the status to the badge element. Returns false when the badge is
 * not present in the current DOM (for example before the room renders it).
 */
export function renderSyncStatus(element, { driftMs = null, isHost = false, status }) {
  const textElement = element?.querySelector?.("[data-sync-status-text]");
  if (!element || !textElement) return false;

  textElement.textContent = syncStatusText({ driftMs, isHost, status });
  element.dataset.syncState = status;
  element.classList.remove(...STATUS_CLASSES);
  element.classList.add(...syncStatusClasses({ isHost, status }));
  return true;
}
