import assert from "node:assert/strict";
import test from "node:test";
import { OFFLINE_SYNC_RETRY_EVENT, requestOfflineSyncRetry } from "../pwa/offline_sync_events.js";

test("requests one offline resync through the shared browser event", () => {
  const target = new EventTarget();
  let attempts = 0;
  target.addEventListener(OFFLINE_SYNC_RETRY_EVENT, () => {
    attempts += 1;
  });

  requestOfflineSyncRetry(target);

  assert.equal(attempts, 1);
  assert.equal(OFFLINE_SYNC_RETRY_EVENT, "streamix:offline-sync-retry");
});
