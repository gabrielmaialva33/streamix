import assert from "node:assert/strict";
import test from "node:test";
import { createOfflineAccountSession } from "../pwa/offline_account_session.js";

function fixture() {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
  const removed = [];
  const indexedDB = { deleteDatabase: (name) => removed.push(name) };
  let nonce = 0;
  const session = () =>
    createOfflineAccountSession({ storage, indexedDB, nonce: () => String(++nonce) });
  return { session, removed };
}
const alice = "a".repeat(43);
const bob = "b".repeat(43);

test("offline persistence is opt in; logout fences every old tab and removes account and legacy databases", () => {
  const { session, removed } = fixture();
  const a = session();
  a.start(alice);
  assert.throws(() => a.capture(), /disabled/);
  a.setEnabled(true);
  const lease = a.capture();
  const secondTab = session();
  secondTab.start(alice);
  assert.equal(secondTab.capture(), lease);
  a.logout();
  assert.throws(() => secondTab.capture(), /expired/);
  assert.throws(() => a.assert(lease), /expired/);
  assert.ok(removed.includes("streamix-offline"));
  assert.ok(removed.some((name) => name.startsWith(`streamix-offline:${alice}:`)));
  const b = session();
  b.start(bob);
  b.setEnabled(true);
  assert.notEqual(b.capture(), lease);
  assert.throws(() => secondTab.assert(lease), /expired/);
});

test("account switch and disabling offline invalidate an in-flight lease", () => {
  const { session, removed } = fixture();
  const a = session();
  a.start(alice);
  a.setEnabled(true);
  const lease = a.capture();
  const b = session();
  b.start(bob);
  assert.throws(() => a.assert(lease), /expired/);
  assert.ok(removed.some((name) => name.startsWith(`streamix-offline:${alice}:`)));
  b.setEnabled(true);
  const next = b.capture();
  b.setEnabled(false);
  assert.throws(() => b.assert(next), /expired/);
});

test("the browser logout control revokes pending leases before navigation", async () => {
  const { installOfflineAccountSession } = await import("../pwa/offline_account_session.js");
  const values = new Map();
  const documentRef = new EventTarget();
  documentRef.querySelector = () => ({ content: alice });
  documentRef.closest = () => ({});
  const session = installOfflineAccountSession({
    documentRef,
    windowRef: new EventTarget(),
    indexedDB: { deleteDatabase() {} },
    storage: {
      getItem: (key) => values.get(key),
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
  });
  session.setEnabled(true);
  const lease = session.capture();
  documentRef.dispatchEvent(new Event("click"));
  assert.throws(() => session.assert(lease), /expired/);
});

test("consent updates notify the other tab without invalidating its active transaction lease", () => {
  const { session } = fixture();
  const a = session();
  a.start(alice);
  const b = session();
  b.start(alice);
  const choices = [];
  b.subscribe(() => choices.push(b.enabled()));
  a.setEnabled(true);
  b.changed();
  assert.deepEqual(choices, [true]);
  a.setEnabled(false);
  b.changed();
  assert.deepEqual(choices, [true, false]);
  assert.equal(b.current(), false);
  assert.equal(a.current(), true);
});
