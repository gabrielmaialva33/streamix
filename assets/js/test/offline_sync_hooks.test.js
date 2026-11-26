import assert from "node:assert/strict";
import test from "node:test";
import OfflineSync from "../hooks/offline_sync.js";
import PwaRepair from "../hooks/pwa_repair.js";
import { installOfflineAccountSession } from "../pwa/offline_account_session.js";
import { OFFLINE_SYNC_RETRY_EVENT, requestOfflineSyncRetry } from "../pwa/offline_sync_events.js";

test("OfflineSync retries the current snapshot and removes its listener on destroy", (t) => {
  const previousWindow = globalThis.window;
  const browserWindow = new EventTarget();
  globalThis.window = browserWindow;
  t.after(() => {
    globalThis.window = previousWindow;
  });

  const hook = Object.assign(Object.create(OfflineSync), {
    el: { dataset: {} },
    handleEvent() {},
  });

  hook.mounted();
  hook.lastSyncedData = "already-synced";

  requestOfflineSyncRetry(browserWindow);
  assert.equal(hook.lastSyncedData, null);

  hook.destroyed();
  hook.lastSyncedData = "after-destroy";
  requestOfflineSyncRetry(browserWindow);
  assert.equal(hook.lastSyncedData, "after-destroy");
});

test("PwaRepair dispatches a retry from its diagnostic button and cleans up", (t) => {
  const previousWindow = globalThis.window;
  const browserWindow = new EventTarget();
  globalThis.window = browserWindow;
  t.after(() => {
    globalThis.window = previousWindow;
  });

  class FakeButton extends EventTarget {
    constructor(text) {
      super();
      this.dataset = {};
      this.disabled = false;
      this.textContent = text;
    }
  }

  const status = { textContent: "" };
  const repairButton = new FakeButton("Atualizar");
  const clearButton = new FakeButton("Limpar");
  const syncButton = new FakeButton("Sincronizar");
  const elements = new Map([
    ["[data-pwa-repair-status]", status],
    ["[data-pwa-repair-action='repair']", repairButton],
    ["[data-pwa-repair-action='clear']", clearButton],
    ["[data-pwa-repair-action='sync']", syncButton],
  ]);
  const hook = Object.assign(Object.create(PwaRepair), {
    el: { querySelector: (selector) => elements.get(selector) },
  });
  let retries = 0;
  browserWindow.addEventListener(OFFLINE_SYNC_RETRY_EVENT, () => {
    retries += 1;
  });

  hook.mounted();
  syncButton.dispatchEvent(new Event("click"));

  assert.equal(retries, 1);
  assert.equal(status.textContent, "Nova sincronização offline solicitada.");

  hook.destroyed();
  syncButton.dispatchEvent(new Event("click"));
  assert.equal(retries, 1);
});

test("open tabs show shared consent and an expired tab offers an actual reload", (t) => {
  const previous = globalThis.window;
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
  const documentRef = { querySelector: () => ({ content: "a".repeat(43) }), addEventListener() {} };
  const a = installOfflineAccountSession({
    storage,
    documentRef,
    indexedDB: { deleteDatabase() {} },
    windowRef: new EventTarget(),
  });
  const browserWindow = new EventTarget();
  let reloads = 0;
  browserWindow.location = { reload: () => reloads++ };
  globalThis.window = browserWindow;
  installOfflineAccountSession({
    storage,
    documentRef,
    indexedDB: { deleteDatabase() {} },
    windowRef: browserWindow,
  });
  const choice = new EventTarget();
  const reload = new EventTarget();
  const notice = { hidden: true };
  const elements = {
    "[data-offline-opt-in]": choice,
    "[data-offline-expired]": notice,
    "[data-offline-reload]": reload,
  };
  const hook = Object.assign(Object.create(OfflineSync), {
    el: { dataset: {}, querySelector: (key) => elements[key] },
    handleEvent() {},
  });
  hook.mounted();
  t.after(() => {
    hook.destroyed();
    globalThis.window = previous;
  });
  assert.equal(choice.checked, false);
  a.setEnabled(true);
  browserWindow.dispatchEvent(new Event("storage"));
  assert.equal(choice.checked, true);
  assert.equal(choice.disabled, false);
  a.setEnabled(false);
  browserWindow.dispatchEvent(new Event("storage"));
  assert.equal(choice.checked, false);
  assert.equal(choice.disabled, true);
  assert.equal(notice.hidden, false);
  reload.dispatchEvent(new Event("click"));
  assert.equal(reloads, 1);
});
