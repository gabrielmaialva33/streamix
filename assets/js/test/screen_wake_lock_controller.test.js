import assert from "node:assert/strict";
import test from "node:test";
import { createScreenWakeLockController } from "../player/screen_wake_lock_controller.js";

class FakeDocument extends EventTarget {
  constructor() {
    super();
    this.visibilityState = "visible";
  }

  setVisibility(state) {
    this.visibilityState = state;
    this.dispatchEvent(new Event("visibilitychange"));
  }
}

class FakeWakeLockSentinel extends EventTarget {
  constructor() {
    super();
    this.released = false;
    this.releaseCalls = 0;
  }

  async release() {
    if (this.released) return;
    this.releaseCalls += 1;
    this.released = true;
    this.dispatchEvent(new Event("release"));
  }
}

test("holds one screen wake lock only while playback is active", async () => {
  const documentRef = new FakeDocument();
  const sentinels = [];
  const requests = [];
  const controller = createScreenWakeLockController({
    documentRef,
    navigatorRef: {
      wakeLock: {
        async request(type) {
          requests.push(type);
          const sentinel = new FakeWakeLockSentinel();
          sentinels.push(sentinel);
          return sentinel;
        },
      },
    },
  });

  await Promise.all([controller.setActive(true), controller.sync(), controller.acquire()]);

  assert.deepEqual(requests, ["screen"]);
  assert.equal(controller.active, true);
  assert.equal(controller.held, true);

  await controller.setActive(false);

  assert.equal(sentinels[0].releaseCalls, 1);
  assert.equal(controller.active, false);
  assert.equal(controller.held, false);
});

test("releases while hidden and reacquires when visible playback resumes", async () => {
  const documentRef = new FakeDocument();
  const sentinels = [];
  const controller = createScreenWakeLockController({
    documentRef,
    navigatorRef: {
      wakeLock: {
        async request() {
          const sentinel = new FakeWakeLockSentinel();
          sentinels.push(sentinel);
          return sentinel;
        },
      },
    },
  });

  await controller.setActive(true);
  documentRef.setVisibility("hidden");
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(sentinels[0].released, true);
  assert.equal(controller.held, false);

  documentRef.setVisibility("visible");
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(sentinels.length, 2);
  assert.equal(controller.held, true);

  await controller.destroy();
  assert.equal(sentinels[1].released, true);
});

test("contains unsupported, rejected, and stale wake-lock requests", async () => {
  const documentRef = new FakeDocument();
  const errors = [];
  const unsupported = createScreenWakeLockController({ documentRef, navigatorRef: {} });

  assert.equal(await unsupported.setActive(true), null);
  await unsupported.destroy();

  const rejected = createScreenWakeLockController({
    documentRef,
    navigatorRef: {
      wakeLock: {
        request: async () => {
          throw new Error("denied");
        },
      },
    },
    onError: (error) => errors.push(error.message),
  });

  assert.equal(await rejected.setActive(true), null);
  assert.deepEqual(errors, ["denied"]);
  await rejected.destroy();

  let resolveRequest;
  const staleSentinel = new FakeWakeLockSentinel();
  const stale = createScreenWakeLockController({
    documentRef,
    navigatorRef: {
      wakeLock: {
        request: () =>
          new Promise((resolve) => {
            resolveRequest = resolve;
          }),
      },
    },
  });

  const acquisition = stale.setActive(true);
  await stale.setActive(false);
  resolveRequest(staleSentinel);
  await acquisition;

  assert.equal(staleSentinel.released, true);
  assert.equal(stale.held, false);
});
