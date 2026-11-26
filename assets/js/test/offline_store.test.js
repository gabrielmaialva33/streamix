import assert from "node:assert/strict";
import test from "node:test";
import { installOfflineAccountSession } from "../pwa/offline_account_session.js";
import {
  favoriteKey,
  normalizeFavorite,
  removeFavorite,
  syncFavorites,
} from "../pwa/offline_store.js";

test("derives a stable favorite key from supported content identities", () => {
  assert.equal(favoriteKey("movie", 42), "movie:42");
  assert.equal(favoriteKey("live_channel", "0007"), "live_channel:7");
  assert.equal(favoriteKey("series", "9007199254740993"), "series:9007199254740993");
});

test("normalizes a favorite without trusting a supplied storage key", () => {
  assert.deepEqual(
    normalizeFavorite(
      {
        id: "attacker-controlled",
        content_type: "episode",
        content_id: "00019",
        content_name: "Episódio 19",
      },
      1234,
    ),
    {
      id: "episode:19",
      content_type: "episode",
      content_id: "19",
      content_name: "Episódio 19",
      synced_at: 1234,
    },
  );
});

test("rejects a complete invalid snapshot before opening IndexedDB", async (t) => {
  let openCalls = 0;
  globalThis.indexedDB = {
    open() {
      openCalls += 1;
      throw new Error("IndexedDB must not be opened");
    },
  };
  t.after(() => {
    delete globalThis.indexedDB;
  });

  await assert.rejects(
    syncFavorites([{ content_type: "movie", content_id: 1 }, { content_type: "movie" }]),
    /invalid content_id/,
  );
  assert.equal(openCalls, 0);
});

test("rejects unsupported types, zero, and oversized ids", () => {
  assert.throws(() => favoriteKey("channel", 1), /invalid content_type/);
  assert.throws(() => favoriteKey("movie", 0), /invalid content_id/);
  assert.throws(() => favoriteKey("movie", "12345678901234567890"), /invalid content_id/);
});

test("removes a favorite by its composite key without scanning the store", async (t) => {
  let deletedKey = null;
  let cursorOpened = false;

  const transaction = {
    objectStore() {
      return {
        delete(key) {
          deletedKey = key;
          queueMicrotask(() => transaction.oncomplete?.());
        },
        openCursor() {
          cursorOpened = true;
          const request = {};
          queueMicrotask(() => request.onsuccess?.({ target: { result: null } }));
          return request;
        },
      };
    },
  };
  const database = {
    close() {},
    transaction() {
      return transaction;
    },
  };

  globalThis.indexedDB = {
    deleteDatabase() {},
    open() {
      const request = { result: database };
      queueMicrotask(() => request.onsuccess?.());
      return request;
    },
  };
  t.after(() => {
    delete globalThis.indexedDB;
  });

  const values = new Map();
  const session = installOfflineAccountSession({
    storage: {
      getItem: (key) => values.get(key),
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
    documentRef: { querySelector: () => ({ content: "a".repeat(43) }), addEventListener() {} },
    windowRef: new EventTarget(),
    indexedDB: globalThis.indexedDB,
  });
  session.setEnabled(true);
  t.after(() => session.logout());
  assert.equal(await removeFavorite("movie", "00042"), true);
  assert.equal(deletedKey, "movie:42");
  assert.equal(cursorOpened, false);
});

test("logout during an IDB open closes the late handle without writing or recreating personal data", async (t) => {
  const values = new Map();
  const opened = [];
  const deleted = [];
  let writes = 0;
  let closes = 0;
  const idb = {
    deleteDatabase: (name) => deleted.push(name),
    open(name) {
      const request = {
        result: {
          close: () => closes++,
          transaction: () => {
            writes++;
            throw new Error("must not write");
          },
        },
      };
      opened.push({ name, request });
      return request;
    },
  };
  globalThis.indexedDB = idb;
  t.after(() => {
    delete globalThis.indexedDB;
  });
  const session = installOfflineAccountSession({
    storage: {
      getItem: (key) => values.get(key),
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
    documentRef: { querySelector: () => ({ content: "b".repeat(43) }), addEventListener() {} },
    windowRef: new EventTarget(),
    indexedDB: idb,
  });
  session.setEnabled(true);
  const pending = syncFavorites([{ content_type: "movie", content_id: 42 }]);
  const rejected = assert.rejects(pending, /expired/);
  assert.equal(opened.length, 1);
  session.logout();
  opened[0].request.onsuccess();
  await rejected;
  assert.equal(writes, 0);
  assert.equal(closes, 1);
  assert.ok(deleted.includes(opened[0].name));
});

test("logout aborts an already-created write transaction and rejects its sync", async (t) => {
  const values = new Map();
  let started;
  const writing = new Promise((resolve) => {
    started = resolve;
  });
  let aborted = 0;
  let closed = 0;
  const tx = new EventTarget();
  tx.objectStore = () => ({
    clear() {},
    put() {
      started();
    },
  });
  tx.abort = () => {
    aborted++;
    queueMicrotask(() => tx.onabort?.());
  };
  const database = { transaction: () => tx, close: () => closed++ };
  const idb = {
    deleteDatabase() {},
    open() {
      const request = { result: database };
      queueMicrotask(() => request.onsuccess());
      return request;
    },
  };
  globalThis.indexedDB = idb;
  t.after(() => {
    delete globalThis.indexedDB;
  });
  const session = installOfflineAccountSession({
    storage: {
      getItem: (key) => values.get(key),
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
    documentRef: { querySelector: () => ({ content: "c".repeat(43) }), addEventListener() {} },
    windowRef: new EventTarget(),
    indexedDB: idb,
  });
  session.setEnabled(true);
  const pending = assert.rejects(
    syncFavorites([{ content_type: "movie", content_id: 1 }]),
    /expired/,
  );
  await writing;
  session.logout();
  await pending;
  assert.equal(aborted, 1);
  assert.equal(closed, 1);
});
