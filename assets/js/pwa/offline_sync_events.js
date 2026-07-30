export const OFFLINE_SYNC_RETRY_EVENT = "streamix:offline-sync-retry";

export function requestOfflineSyncRetry(target = window) {
  if (!target || typeof target.dispatchEvent !== "function") {
    throw new TypeError("[OfflineSync] retry target must support dispatchEvent");
  }

  target.dispatchEvent(new Event(OFFLINE_SYNC_RETRY_EVENT));
}
