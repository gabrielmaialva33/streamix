import assert from "node:assert/strict";
import test from "node:test";

import { createControllerChangeGuard } from "../lib/service_worker_runtime.js";

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
