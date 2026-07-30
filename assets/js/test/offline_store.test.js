import assert from "node:assert/strict";
import test from "node:test";
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
    transaction() {
      return transaction;
    },
  };

  globalThis.indexedDB = {
    open() {
      const request = { result: database };
      queueMicrotask(() => request.onsuccess?.());
      return request;
    },
  };
  t.after(() => {
    delete globalThis.indexedDB;
  });

  assert.equal(await removeFavorite("movie", "00042"), true);
  assert.equal(deletedKey, "movie:42");
  assert.equal(cursorOpened, false);
});
