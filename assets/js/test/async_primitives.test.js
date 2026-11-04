import assert from "node:assert/strict";
import test from "node:test";
import { AvbridgeWrapper } from "../media/avbridge_wrapper.js";
import { H265webWrapper } from "../media/h265web_wrapper.js";

for (const Wrapper of [AvbridgeWrapper, H265webWrapper]) {
  test(`${Wrapper.name} preserves duplicate listeners, delivery order and removal during emission`, () => {
    const wrapper = new Wrapper({ video: { style: {} }, mountEl: {} });
    const calls = [];
    const duplicate = () => calls.push("duplicate");
    wrapper.on("tick", () => {
      calls.push("first");
      wrapper.off("tick", duplicate);
    });
    wrapper.on("tick", duplicate);
    wrapper.on("tick", duplicate);
    wrapper._emit("tick");
    assert.deepEqual(calls, ["first", "duplicate", "duplicate"]);
    calls.length = 0;
    wrapper._emit("tick");
    assert.deepEqual(calls, ["first"]);
    wrapper.events.clear();
    wrapper._emit("tick");
    assert.deepEqual(calls, ["first"]);
  });
}

test("timeouts settle once and clear deadlines after success, rejection and expiry", async () => {
  const { withTimeout } = await import("../core/async_primitives.js");
  const pending = new Map();
  let nextId = 0;
  const timerApi = {
    setTimeout: (callback) => {
      pending.set(++nextId, callback);
      return nextId;
    },
    clearTimeout: (id) => pending.delete(id),
  };
  assert.equal(await withTimeout(Promise.resolve(42), { timerApi, timeoutMs: 5 }), 42);
  assert.equal(pending.size, 0);
  await assert.rejects(
    withTimeout(Promise.reject(new Error("failed")), { timerApi, timeoutMs: 5 }),
    /failed/,
  );
  assert.equal(pending.size, 0);
  const result = withTimeout(new Promise(() => {}), {
    timerApi,
    timeoutMs: 5,
    onTimeout: () => "expired",
  });
  [...pending.values()][0]();
  assert.equal(await result, "expired");
  assert.equal(pending.size, 0);
});

test("memoized imports share an attempt and retry synchronous or async rejection", async () => {
  const { memoizeImport } = await import("../core/async_primitives.js");
  let attempts = 0;
  const load = memoizeImport(() => {
    attempts++;
    if (attempts === 1) throw new Error("sync");
    if (attempts === 2) return Promise.reject(new Error("async"));
    return { loaded: true };
  });
  const first = load();
  assert.equal(load(), first);
  await assert.rejects(first, /sync/);
  await assert.rejects(load(), /async/);
  assert.deepEqual(await load(), { loaded: true });
  assert.equal(await load(), await load());
  assert.equal(attempts, 3);
});
