const ACTIVE = "streamix:offline-account";
const ENABLED = "streamix:offline-enabled";
const validScope = (scope) => /^[A-Za-z0-9_-]{43}$/.test(scope || "");

// Each document captures a lease. Storage events are only a cleanup hint: every
// operation also checks shared storage synchronously, including after IDB opens.
export function createOfflineAccountSession({
  storage,
  indexedDB,
  nonce = () => crypto.randomUUID(),
}) {
  let lease = null;
  let scope = null;
  const listeners = new Set();
  const removeDB = (name) => {
    try {
      indexedDB?.deleteDatabase(name);
    } catch {}
  };
  const notify = () => {
    for (const listener of listeners) listener();
  };
  const current = () => storage.getItem(ACTIVE);
  const purge = (value) => {
    notify();
    removeDB("streamix-offline");
    const oldScope = value?.split(":")[0];
    if (validScope(oldScope)) removeDB(`streamix-offline:${value}`);
  };
  const assert = (captured) => {
    if (!lease || captured !== lease || current() !== lease)
      throw new Error("Offline session expired");
    if (storage.getItem(ENABLED) !== lease) throw new Error("Offline persistence disabled");
  };
  return {
    start(nextScope) {
      scope = validScope(nextScope) ? nextScope : null;
      const previous = current();
      if (scope && previous?.startsWith(`${scope}:`)) lease = previous;
      else {
        lease = scope ? `${scope}:${nonce()}` : null;
        if (lease) storage.setItem(ACTIVE, lease);
        else storage.removeItem(ACTIVE);
        storage.removeItem(ENABLED);
        purge(previous);
      }
      removeDB("streamix-offline");
    },
    capture() {
      assert(lease);
      return lease;
    },
    assert,
    databaseName: () => `streamix-offline:${lease}`,
    enabled() {
      try {
        assert(lease);
        return true;
      } catch {
        return false;
      }
    },
    setEnabled(enabled) {
      if (!lease || current() !== lease) throw new Error("Offline session expired");
      if (enabled) storage.setItem(ENABLED, lease);
      else {
        const previous = lease;
        lease = `${scope}:${nonce()}`;
        storage.setItem(ACTIVE, lease);
        storage.removeItem(ENABLED);
        purge(previous);
      }
    },
    logout() {
      // A stale tab cannot log out or delete the new account's storage.
      if (current() === lease) {
        storage.removeItem(ACTIVE);
        storage.removeItem(ENABLED);
      }
      purge(lease);
      lease = null;
    },
    changed() {
      if (!this.enabled()) notify();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

let session = null;
export function offlineAccountSession() {
  if (!session) throw new Error("Offline session unavailable");
  return session;
}

export function installOfflineAccountSession({
  documentRef = document,
  windowRef = window,
  storage = localStorage,
  indexedDB = globalThis.indexedDB,
} = {}) {
  session = createOfflineAccountSession({ storage, indexedDB });
  const active = session;
  active.start(documentRef.querySelector('meta[name="streamix-storage-scope"]')?.content);
  windowRef.addEventListener("storage", () => active.changed());
  windowRef.addEventListener("pageshow", () => active.changed());
  const onLogout = (event) => {
    const element = event.target?.closest?.('a[href="/logout"], form[action="/logout"]');
    if (element) active.logout();
  };
  documentRef.addEventListener("click", onLogout, true);
  documentRef.addEventListener("submit", onLogout, true);
  return active;
}
