import assert from "node:assert/strict";
import test from "node:test";
import { inspect } from "node:util";
import { createLogger, setLogLevel } from "../core/logger.js";

test("console diagnostics omit stream URLs and credentials even in debug mode", (t) => {
  const calls = [];
  t.mock.method(console, "log", (...args) => calls.push(args));
  setLogLevel("debug");
  t.after(() => setLogLevel("warn"));
  const details = { streamUrl: "/api/stream?token=PRIVATE", token: "PRIVATE" };
  details.self = details;
  createLogger("test").debug(
    "Failed https://example.test/PRIVATE",
    details,
    new Error("fetch https://example.test/PRIVATE"),
  );
  const output = inspect(calls, { depth: 8 });
  assert.doesNotMatch(output, /PRIVATE|example\.test/);
  assert.match(output, /Failed/);
});
