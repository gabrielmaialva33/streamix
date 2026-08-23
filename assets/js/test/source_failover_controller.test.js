import assert from "node:assert/strict";
import test from "node:test";

import { createSourceFailoverController } from "../player/source_failover_controller.js";

function statusFixture() {
  const classes = new Set(["hidden"]);
  const text = { textContent: "" };

  return {
    dataset: {},
    classList: {
      add(...values) {
        for (const value of values) classes.add(value);
      },
      remove(...values) {
        for (const value of values) classes.delete(value);
      },
      contains(value) {
        return classes.has(value);
      },
    },
    querySelector(selector) {
      return selector === "[data-source-failover-text]" ? text : null;
    },
    text,
  };
}

function timerFixture() {
  const callbacks = new Map();
  let nextId = 0;

  return {
    api: {
      setTimeout(callback) {
        nextId += 1;
        callbacks.set(nextId, callback);
        return nextId;
      },
      clearTimeout(id) {
        callbacks.delete(id);
      },
    },
    flush() {
      for (const callback of callbacks.values()) callback();
      callbacks.clear();
    },
  };
}

function sequentialRequestIds(prefix = "request") {
  return (sequence) => `${prefix}-${sequence}`;
}

test("requests one correlated failover while a source lookup is pending", () => {
  const requests = [];
  const status = statusFixture();
  const controller = createSourceFailoverController({
    enabled: true,
    pushRequest: (payload) => requests.push(payload),
    requestIdFactory: sequentialRequestIds(),
    statusElement: status,
  });

  assert.equal(
    controller.request({ contentId: "42", position: 18.5, reason: "network failure" }),
    true,
  );
  assert.equal(controller.pending, true);
  assert.equal(controller.activeRequestId, "request-1");
  assert.equal(controller.request({ contentId: 42, position: 20 }), false);
  assert.deepEqual(requests, [
    { content_id: 42, position: 18.5, reason: "network failure", request_id: "request-1" },
  ]);
  assert.equal(status.classList.contains("hidden"), false);
  assert.equal(status.text.textContent, "Procurando outra fonte disponível…");
});

test("applies a valid correlated replacement and normalizes its resume position", () => {
  const applied = [];
  const status = statusFixture();
  const timer = timerFixture();
  const controller = createSourceFailoverController({
    enabled: true,
    onApply: (payload) => applied.push(payload),
    pushRequest: () => {},
    requestIdFactory: sequentialRequestIds(),
    statusElement: status,
    timerApi: timer.api,
  });

  controller.request({ contentId: 1, position: 9 });

  assert.equal(
    controller.apply({
      content_id: "2",
      request_id: "request-1",
      stream_url: " /api/stream/proxy?token=next ",
      resume_time: "15.25",
      message: "Fonte B ativada.",
    }),
    true,
  );
  assert.equal(controller.pending, false);
  assert.equal(controller.exhausted, false);
  assert.equal(controller.activeRequestId, null);
  assert.equal(applied[0].content_id, 2);
  assert.equal(applied[0].request_id, "request-1");
  assert.equal(applied[0].resume_time, 15.25);
  assert.equal(applied[0].stream_url, "/api/stream/proxy?token=next");
  assert.equal(status.text.textContent, "Fonte B ativada.");

  timer.flush();
  assert.equal(status.classList.contains("hidden"), true);
});

test("marks the source set exhausted and returns the original terminal error", () => {
  const failures = [];
  const controller = createSourceFailoverController({
    enabled: true,
    onUnavailable: (terminalError, payload) => failures.push({ terminalError, payload }),
    pushRequest: () => {},
    requestIdFactory: sequentialRequestIds(),
  });

  controller.request({ contentId: 7, position: Number.NaN, reason: "codec failed" });
  controller.unavailable({ request_id: "request-1", message: "Sem alternativa" });

  assert.equal(controller.pending, false);
  assert.equal(controller.exhausted, true);
  assert.equal(controller.activeRequestId, null);
  assert.deepEqual(failures, [
    {
      terminalError: { message: "codec failed" },
      payload: { request_id: "request-1", message: "Sem alternativa" },
    },
  ]);
  assert.equal(controller.request({ contentId: 7 }), false);

  controller.reset();
  assert.equal(controller.exhausted, false);
  assert.equal(controller.request({ contentId: 7 }), true);
});

test("contains disabled, malformed, whitespace-only, and destroyed requests", () => {
  const disabled = createSourceFailoverController({ enabled: false });
  assert.equal(disabled.request({ contentId: 1 }), false);

  const enabled = createSourceFailoverController({
    enabled: true,
    pushRequest: () => {},
    requestIdFactory: sequentialRequestIds(),
  });
  assert.equal(enabled.request({ contentId: "bad" }), false);
  assert.equal(enabled.apply({ content_id: 2, request_id: "request-1", stream_url: "   " }), false);
  enabled.destroy();
  assert.equal(enabled.request({ contentId: 2 }), false);
});

test("times out a lost source lookup without leaving the player pending forever", () => {
  const failures = [];
  const status = statusFixture();
  const timer = timerFixture();
  const controller = createSourceFailoverController({
    enabled: true,
    onUnavailable: (terminalError, payload) => failures.push({ terminalError, payload }),
    pushRequest: () => {},
    requestIdFactory: sequentialRequestIds("timeout"),
    statusElement: status,
    timerApi: timer.api,
    requestTimeoutMs: 10,
  });

  assert.equal(
    controller.request({ contentId: 9, position: 12, reason: "upstream disconnected" }),
    true,
  );
  assert.equal(controller.pending, true);

  timer.flush();

  assert.equal(controller.pending, false);
  assert.equal(controller.exhausted, true);
  assert.equal(controller.activeRequestId, null);
  assert.deepEqual(failures, [
    {
      terminalError: { message: "upstream disconnected" },
      payload: {
        request_id: "timeout-1",
        reason: "timeout",
        message: "A busca por outra fonte demorou demais.",
      },
    },
  ]);
  assert.equal(controller.request({ contentId: 9 }), false);

  assert.equal(
    controller.apply({
      content_id: 10,
      request_id: "timeout-1",
      stream_url: "/api/stream/proxy?token=late",
    }),
    false,
  );
  assert.equal(
    controller.unavailable({ request_id: "timeout-1", message: "late unavailable" }),
    false,
  );
  assert.equal(controller.exhausted, true);
});

test("ignores stale responses after reset and a newer request", () => {
  const applied = [];
  const failures = [];
  const controller = createSourceFailoverController({
    enabled: true,
    onApply: (payload) => applied.push(payload),
    onUnavailable: (terminalError, payload) => failures.push({ terminalError, payload }),
    pushRequest: () => {},
    requestIdFactory: sequentialRequestIds("attempt"),
  });

  controller.request({ contentId: 1, reason: "first failed" });
  controller.reset();
  controller.request({ contentId: 2, reason: "second failed" });

  assert.equal(
    controller.apply({
      content_id: 3,
      request_id: "attempt-1",
      stream_url: "/api/stream/proxy?token=stale",
    }),
    false,
  );
  assert.equal(
    controller.unavailable({ request_id: "attempt-1", message: "stale unavailable" }),
    false,
  );
  assert.equal(controller.pending, true);
  assert.deepEqual(applied, []);
  assert.deepEqual(failures, []);

  assert.equal(
    controller.apply({
      content_id: 4,
      request_id: "attempt-2",
      stream_url: "/api/stream/proxy?token=current",
    }),
    true,
  );
  assert.equal(applied[0].request_id, "attempt-2");
});
