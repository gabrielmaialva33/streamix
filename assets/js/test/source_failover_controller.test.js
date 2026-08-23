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

test("requests one failover while a source lookup is pending", () => {
  const requests = [];
  const status = statusFixture();
  const controller = createSourceFailoverController({
    enabled: true,
    pushRequest: (payload) => requests.push(payload),
    statusElement: status,
  });

  assert.equal(
    controller.request({ contentId: "42", position: 18.5, reason: "network failure" }),
    true,
  );
  assert.equal(controller.pending, true);
  assert.equal(controller.request({ contentId: 42, position: 20 }), false);
  assert.deepEqual(requests, [{ content_id: 42, position: 18.5, reason: "network failure" }]);
  assert.equal(status.classList.contains("hidden"), false);
  assert.equal(status.text.textContent, "Procurando outra fonte disponível…");
});

test("applies a valid replacement and normalizes its resume position", () => {
  const applied = [];
  const status = statusFixture();
  const timer = timerFixture();
  const controller = createSourceFailoverController({
    enabled: true,
    onApply: (payload) => applied.push(payload),
    pushRequest: () => {},
    statusElement: status,
    timerApi: timer.api,
  });

  controller.request({ contentId: 1, position: 9 });

  assert.equal(
    controller.apply({
      content_id: "2",
      stream_url: "/api/stream/proxy?token=next",
      resume_time: "15.25",
      message: "Fonte B ativada.",
    }),
    true,
  );
  assert.equal(controller.pending, false);
  assert.equal(controller.exhausted, false);
  assert.equal(applied[0].content_id, 2);
  assert.equal(applied[0].resume_time, 15.25);
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
  });

  controller.request({ contentId: 7, position: Number.NaN, reason: "codec failed" });
  controller.unavailable({ message: "Sem alternativa" });

  assert.equal(controller.pending, false);
  assert.equal(controller.exhausted, true);
  assert.deepEqual(failures, [
    {
      terminalError: { message: "codec failed" },
      payload: { message: "Sem alternativa" },
    },
  ]);
  assert.equal(controller.request({ contentId: 7 }), false);

  controller.reset();
  assert.equal(controller.exhausted, false);
  assert.equal(controller.request({ contentId: 7 }), true);
});

test("contains disabled, malformed, and destroyed requests", () => {
  const disabled = createSourceFailoverController({ enabled: false });
  assert.equal(disabled.request({ contentId: 1 }), false);

  const enabled = createSourceFailoverController({ enabled: true, pushRequest: () => {} });
  assert.equal(enabled.request({ contentId: "bad" }), false);
  assert.equal(enabled.apply({ content_id: 2 }), false);
  enabled.destroy();
  assert.equal(enabled.request({ contentId: 2 }), false);
});
