import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_ID } from "../player/engine_contract.js";
import { createEngineRegistry } from "../player/engine_registry.js";

function engineDouble(label, overrides = {}) {
  const calls = [];
  return {
    label,
    calls,
    destroyed: false,
    load() {},
    play() {},
    pause() {},
    seek() {},
    destroy() {
      calls.push(["destroy"]);
      this.destroyed = true;
      return Promise.resolve();
    },
    ...overrides,
  };
}

test("registers, activates and snapshots engines", () => {
  const changes = [];
  const registry = createEngineRegistry({ onChange: (change) => changes.push(change) });
  const native = engineDouble("native");

  registry.registerAndActivate(ENGINE_ID.NATIVE, native);

  assert.equal(registry.current(), native);
  assert.equal(registry.currentId(), ENGINE_ID.NATIVE);
  assert.equal(registry.has(ENGINE_ID.NATIVE), true);
  assert.equal(registry.snapshot().activeId, ENGINE_ID.NATIVE);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].engine, native);
});

test("replacing an engine releases the previous adapter", async () => {
  const registry = createEngineRegistry();
  const first = engineDouble("first");
  const second = engineDouble("second");

  registry.registerAndActivate(ENGINE_ID.HLS, first);
  registry.registerAndActivate(ENGINE_ID.HLS, second);
  await Promise.resolve();

  assert.deepEqual(first.calls, [["destroy"]]);
  assert.equal(registry.current(), second);
});

test("rejects unknown IDs and incomplete engines", () => {
  const registry = createEngineRegistry();

  assert.throws(() => registry.register("invented", engineDouble("x")), /known engine id/);
  assert.throws(
    () => registry.register(ENGINE_ID.NATIVE, { play() {} }),
    /playback engine contract|missing required/i,
  );
});

test("can track an engine without taking teardown ownership", async () => {
  const registry = createEngineRegistry();
  const managedElsewhere = engineDouble("managed-elsewhere");

  registry.registerAndActivate(ENGINE_ID.AVPLAYER, managedElsewhere, {
    registryOwnsEngine: false,
  });
  assert.equal(registry.snapshot().engines.avplayer.registryOwnsEngine, false);

  assert.equal(registry.release(ENGINE_ID.AVPLAYER), managedElsewhere);
  registry.destroy();
  await Promise.resolve();

  assert.deepEqual(managedElsewhere.calls, []);
});

test("release and destroy are idempotent", async () => {
  const registry = createEngineRegistry();
  const native = engineDouble("native");
  const hls = engineDouble("hls");

  registry.registerAndActivate(ENGINE_ID.NATIVE, native);
  registry.register(ENGINE_ID.HLS, hls);

  assert.equal(registry.release(ENGINE_ID.NATIVE), native);
  assert.equal(registry.release(ENGINE_ID.NATIVE), null);
  assert.equal(registry.current(), null);
  assert.equal(registry.destroy(), true);
  assert.equal(registry.destroy(), false);
  await Promise.resolve();

  assert.deepEqual(native.calls, [["destroy"]]);
  assert.deepEqual(hls.calls, [["destroy"]]);
});

test("destroy failures are contained and reported", async () => {
  const errors = [];
  const registry = createEngineRegistry({
    onDestroyError: (error, id) => errors.push([error.message, id]),
  });
  const broken = engineDouble("broken", {
    destroy() {
      return Promise.reject(new Error("boom"));
    },
  });

  registry.register(ENGINE_ID.MPEGTS, broken);
  registry.destroy();
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(errors, [["boom", ENGINE_ID.MPEGTS]]);
});
