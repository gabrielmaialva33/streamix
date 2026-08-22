import assert from "node:assert/strict";
import test from "node:test";

import { NetworkMonitor } from "../media/network_monitor.js";

test("starts once and removes the Network Information listener on stop", () => {
  const calls = [];
  const connection = {
    downlink: 8,
    effectiveType: "4g",
    addEventListener(event, callback) {
      calls.push(["add", event, callback]);
    },
    removeEventListener(event, callback) {
      calls.push(["remove", event, callback]);
    },
  };
  const timerApi = {
    setInterval(callback, delay) {
      calls.push(["interval", callback, delay]);
      return 0;
    },
    clearInterval(id) {
      calls.push(["clear", id]);
    },
  };
  const monitor = new NetworkMonitor({
    navigatorRef: { connection },
    timerApi,
  });

  monitor.start();
  monitor.start();

  const additions = calls.filter(([operation]) => operation === "add");
  const intervals = calls.filter(([operation]) => operation === "interval");
  assert.equal(additions.length, 1);
  assert.equal(intervals.length, 1);

  monitor.stop();
  monitor.stop();

  const removal = calls.find(([operation]) => operation === "remove");
  assert.deepEqual(removal.slice(0, 2), ["remove", "change"]);
  assert.equal(removal[2], additions[0][2]);
  assert.equal(calls.filter(([operation]) => operation === "clear").length, 1);
});
