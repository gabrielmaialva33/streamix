import assert from "node:assert/strict";
import { test } from "node:test";

import { CLIENT_ID_STORAGE_KEY, getClientId, isValidClientId } from "../core/client_identity.js";

function memoryStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (key) => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    map,
  };
}

test("mints a uuid-derived id and persists it under the storage key", () => {
  const storage = memoryStorage();
  const id = getClientId({ storage, randomUUID: () => "123e4567-e89b-12d3-a456-426614174000" });

  assert.equal(id, "123e4567e89b12d3a456426614174000");
  assert.equal(storage.map.get(CLIENT_ID_STORAGE_KEY), id);
  assert.ok(isValidClientId(id));
});

test("reuses the stored id on later calls", () => {
  const storage = memoryStorage({ [CLIENT_ID_STORAGE_KEY]: "stored_client_id_1" });
  let minted = 0;
  const id = getClientId({
    storage,
    randomUUID: () => {
      minted += 1;
      return "should-not-be-used";
    },
  });

  assert.equal(id, "stored_client_id_1");
  assert.equal(minted, 0);
});

test("replaces a malformed stored value", () => {
  const storage = memoryStorage({ [CLIENT_ID_STORAGE_KEY]: "bad value!" });
  const id = getClientId({ storage, randomUUID: () => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" });

  assert.equal(id, "aaaaaaaabbbbccccddddeeeeeeeeeeee");
  assert.equal(storage.map.get(CLIENT_ID_STORAGE_KEY), id);
});

test("survives storage that throws and a missing randomUUID", () => {
  const storage = {
    getItem: () => {
      throw new Error("blocked");
    },
    setItem: () => {
      throw new Error("blocked");
    },
  };
  const id = getClientId({ storage, randomUUID: undefined });

  assert.ok(isValidClientId(id), `expected a valid fallback id, got ${id}`);
});

test("rejects ids outside the accepted shape", () => {
  assert.equal(isValidClientId("short"), false);
  assert.equal(isValidClientId("a".repeat(65)), false);
  assert.equal(isValidClientId(42), false);
  assert.equal(isValidClientId("valid_id-1234"), true);
});
