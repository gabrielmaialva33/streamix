import assert from "node:assert/strict";
import test from "node:test";

import { createLazyModuleLoader } from "../player/playback_module_loader.js";

const silentLogger = { debug() {} };

test("deduplicates concurrent module loads and reuses the selected export", async () => {
  let loadCalls = 0;
  let resolveModule;
  const modulePromise = new Promise((resolve) => {
    resolveModule = resolve;
  });
  const loader = createLazyModuleLoader({
    label: "test",
    logger: silentLogger,
    load() {
      loadCalls += 1;
      return modulePromise;
    },
    select: (module) => module.exported,
  });

  const first = loader();
  const second = loader();
  await Promise.resolve();

  assert.equal(loadCalls, 1);
  resolveModule({ exported: { name: "engine" } });

  const [firstResult, secondResult] = await Promise.all([first, second]);
  assert.strictEqual(firstResult, secondResult);
  assert.strictEqual(await loader(), firstResult);
  assert.equal(loadCalls, 1);
});

test("allows a failed lazy module load to be retried", async () => {
  let attempts = 0;
  const loader = createLazyModuleLoader({
    label: "retryable",
    logger: silentLogger,
    async load() {
      attempts += 1;
      if (attempts === 1) throw new Error("transient import failure");
      return { ready: true };
    },
  });

  await assert.rejects(loader(), /transient import failure/);
  assert.deepEqual(await loader(), { ready: true });
  assert.equal(attempts, 2);
});

test("rejects an invalid lazy module loader at its boundary", () => {
  assert.throws(
    () => createLazyModuleLoader({ label: "invalid", load: null }),
    /requires a load function/,
  );
});
