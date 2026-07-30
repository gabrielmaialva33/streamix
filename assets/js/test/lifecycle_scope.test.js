import assert from "node:assert/strict";
import test from "node:test";

import { LifecycleScope } from "../player/lifecycle_scope.js";

test("dispose removes registered listeners exactly once", () => {
  const target = new EventTarget();
  const scope = new LifecycleScope();
  let calls = 0;

  scope.listen(target, "tick", () => {
    calls += 1;
  });

  target.dispatchEvent(new Event("tick"));
  scope.dispose();
  scope.dispose();
  target.dispatchEvent(new Event("tick"));

  assert.equal(calls, 1);
});

test("dispose reports cleanup failures and still releases later resources", () => {
  const errors = [];
  const releases = [];
  const scope = new LifecycleScope({
    onDisposeError: (error) => errors.push(error),
  });

  scope.add(() => releases.push("first"));
  scope.add(() => {
    throw new Error("broken cleanup");
  });
  scope.add(() => releases.push("last"));

  scope.dispose();

  assert.deepEqual(releases, ["last", "first"]);
  assert.deepEqual(
    errors.map((error) => error.message),
    ["broken cleanup"],
  );
});

test("resources registered after disposal are released immediately", () => {
  const releases = [];
  const scope = new LifecycleScope();

  scope.dispose();
  scope.add(() => releases.push("late"));

  assert.deepEqual(releases, ["late"]);
});

test("listenOptional preserves optional DOM targets without leaking a disposer", () => {
  const scope = new LifecycleScope();

  assert.equal(
    scope.listenOptional(null, "tick", () => {}),
    null,
  );
  assert.equal(scope.disposers.length, 0);
});
