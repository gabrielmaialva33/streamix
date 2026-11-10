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

test("backend error reports retain pathname but omit query, fragment and sensitive context", async (t) => {
  const previous = globalThis.window;
  globalThis.window = {
    location: {
      hostname: "example.test",
      pathname: "/watch/movie/42",
      search: "?token=PRIVATE",
      href: "https://example.test/watch/movie/42?token=PRIVATE#PRIVATE",
    },
  };
  t.after(() => {
    if (previous) globalThis.window = previous;
    else delete globalThis.window;
  });
  t.mock.method(console, "error", () => {});
  const logger = await import("../core/logger.js?report-test");
  let report;
  logger.setErrorReporter((_event, payload) => {
    report = payload;
  });
  logger.createLogger("test").reportError("failed", {
    API_KEY: "PRIVATE",
    error: new Error("https://example.test/PRIVATE"),
  });
  assert.equal(report.url, "/watch/movie/42");
  assert.doesNotMatch(JSON.stringify(report), /PRIVATE|example\.test/);
});
