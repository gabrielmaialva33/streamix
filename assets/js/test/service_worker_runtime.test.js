import assert from "node:assert/strict";
import test from "node:test";

import { parseExpectedCacheName } from "../pwa/cache_management.js";
import { createControllerChangeGuard } from "../pwa/service_worker_runtime.js";

test("extracts the deploy cache name from the service worker source", () => {
  assert.equal(parseExpectedCacheName('const CACHE_VERSION = "v42";'), "streamix-v42");
  assert.equal(parseExpectedCacheName("const OTHER_VALUE = 'v42';"), null);
  assert.equal(parseExpectedCacheName(null), null);
});

test("does not reload when a service worker controls a page for the first time", () => {
  const shouldReload = createControllerChangeGuard(null);
  const firstController = {};

  assert.equal(shouldReload(firstController), false);
  assert.equal(shouldReload({}), true);
});

test("reloads when an existing controller is replaced", () => {
  const shouldReload = createControllerChangeGuard({});

  assert.equal(shouldReload({}), true);
});
