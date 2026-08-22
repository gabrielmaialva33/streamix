import assert from "node:assert/strict";
import test from "node:test";

import { NativeBufferManager } from "../media/native_buffer.js";

const createHarness = () => {
  const calls = [];
  const listeners = new Map();
  const timeouts = [];
  const video = {
    buffered: { length: 0 },
    currentTime: 10,
    paused: false,
    readyState: 2,
    networkState: 2,
    addEventListener(event, callback) {
      listeners.set(event, callback);
    },
    removeEventListener(event, callback) {
      if (listeners.get(event) === callback) listeners.delete(event);
    },
    pause() {
      this.paused = true;
      listeners.get("pause")?.();
    },
    async play() {
      calls.push("play");
      this.paused = false;
    },
  };
  const timerApi = {
    setInterval() {
      return 100;
    },
    clearInterval(id) {
      calls.push(["clearInterval", id]);
    },
    setTimeout(callback, delay) {
      const timer = { callback, delay, id: timeouts.length + 1 };
      timeouts.push(timer);
      return timer.id;
    },
    clearTimeout(id) {
      calls.push(["clearTimeout", id]);
    },
  };
  const manager = new NativeBufferManager(video, {
    recoveryPauseTime: 25,
    timerApi,
  });

  return { calls, listeners, manager, timeouts, video };
};

test("cancels recovery and never resumes after stop", async () => {
  const { calls, manager, timeouts } = createHarness();
  manager.start();
  manager._attemptRecovery();
  const recovery = timeouts.find(({ delay }) => delay === 25);

  manager.stop();
  recovery.callback();
  await Promise.resolve();

  assert.equal(calls.includes("play"), false);
  assert.equal(
    calls.some(([operation]) => operation === "clearTimeout"),
    true,
  );
});

test("an intentional pause cancels an in-flight recovery", async () => {
  const { calls, manager, timeouts } = createHarness();
  manager.start();
  manager._attemptRecovery();
  const recovery = timeouts.find(({ delay }) => delay === 25);

  manager.markIntentionalPause();
  recovery.callback();
  await Promise.resolve();

  assert.equal(calls.includes("play"), false);
  assert.equal(manager.getStatus().isRecovering, false);
});

test("destroy prevents the manager from being started again", () => {
  const { manager } = createHarness();
  manager.start();
  manager.destroy();
  manager.start();

  assert.equal(manager.isRunning, false);
  assert.equal(manager.destroyed, true);
});

test("a user seek cancels recovery without overwriting time or autoplaying", async () => {
  const { calls, listeners, manager, timeouts, video } = createHarness();
  manager.start();
  manager._attemptRecovery();
  const recovery = timeouts.find(({ delay }) => delay === 25);

  video.currentTime = 42;
  listeners.get("seeking")();
  recovery.callback();
  await Promise.resolve();

  assert.equal(video.currentTime, 42);
  assert.equal(calls.includes("play"), false);
  assert.equal(manager.getStatus().isRecovering, false);
});
