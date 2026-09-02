import assert from "node:assert/strict";
import test from "node:test";

import { createSyncStatusPublisher } from "../watch_party/status_publisher.js";

function createBadge() {
  const classes = new Set();
  const text = { textContent: "" };
  return {
    classes,
    dataset: {},
    classList: {
      add: (...names) => {
        for (const name of names) classes.add(name);
      },
      remove: (...names) => {
        for (const name of names) classes.delete(name);
      },
    },
    querySelector: (selector) => (selector === "[data-sync-status-text]" ? text : null),
    text,
  };
}

function createHarness({ badge = createBadge(), context = {}, render } = {}) {
  const pushes = [];
  const state = { holdReason: null, isHost: false, ...context };
  const publisher = createSyncStatusPublisher({
    documentRef: { getElementById: (id) => (id === "watch-party-sync-status" ? badge : null) },
    getContext: () => state,
    push: (event, payload) => pushes.push([event, payload]),
    render,
  });
  return { badge, publisher, pushes, state };
}

test("requires its collaborators", () => {
  assert.throws(() => createSyncStatusPublisher({ push() {} }), /requires getContext\(\)/);
  assert.throws(() => createSyncStatusPublisher({ getContext() {} }), /requires push\(\)/);
});

test("publishes resolved status once, re-renders locally and throttles drift", () => {
  const { badge, publisher, pushes } = createHarness();

  assert.equal(publisher.publish("correcting", 240), true);
  assert.equal(badge.text.textContent, "Ajustando sincronização (240 ms)");
  assert.equal(badge.dataset.syncState, "correcting");
  assert.ok(badge.classes.has("bg-warning/90"));

  assert.equal(
    publisher.publish("correcting", 290),
    false,
    "drift below 100 ms is not republished",
  );
  assert.equal(badge.text.textContent, "Ajustando sincronização (290 ms)", "but the badge follows");
  assert.equal(publisher.publish("correcting", 360), true);
  assert.equal(publisher.publish("synced", 20), true);
  assert.deepEqual(pushes, [
    ["wp_sync_status", { status: "correcting", drift_ms: 240 }],
    ["wp_sync_status", { status: "correcting", drift_ms: 360 }],
    ["wp_sync_status", { status: "synced", drift_ms: 20 }],
  ]);
  assert.deepEqual(publisher.snapshot(), { drift: 20, status: "synced" });
});

test("hold reasons and host role take precedence through the injected context", () => {
  const { publisher, pushes, state } = createHarness({ context: { holdReason: "buffering" } });

  publisher.publish("correcting");
  assert.deepEqual(pushes.at(-1), ["wp_sync_status", { status: "buffering", drift_ms: null }]);

  state.holdReason = null;
  state.isHost = true;
  publisher.publish("correcting");
  assert.deepEqual(pushes.at(-1), ["wp_sync_status", { status: "synced", drift_ms: null }]);
  assert.equal(publisher.text("synced"), "Você controla a reprodução");

  state.isHost = false;
  assert.equal(publisher.text("host_offline"), "Anfitrião desconectado — aguardando retorno");
});

test("rerender replays the last published status and tolerates a missing badge", () => {
  const { badge, publisher } = createHarness();
  assert.equal(publisher.rerender(), false, "nothing published yet");

  publisher.publish("connecting");
  badge.text.textContent = "";
  assert.equal(publisher.rerender(), true);
  assert.equal(badge.text.textContent, "Conectando à sincronização");

  const detached = createSyncStatusPublisher({
    documentRef: { getElementById: () => null },
    getContext: () => ({}),
    push: () => {},
  });
  assert.equal(detached.publish("synced"), true, "pushes still happen without a badge");
  assert.equal(detached.rerender(), false);
});

test("an injected render intercepts badge updates while renderBadge still reaches the DOM", () => {
  const rendered = [];
  const { badge, publisher } = createHarness({
    render: (status, drift) => rendered.push([status, drift]),
  });

  publisher.publish("correcting", 150);
  assert.deepEqual(rendered, [["correcting", 150]]);
  assert.equal(badge.text.textContent, "", "the override replaced the DOM render");

  assert.equal(publisher.renderBadge("synced", 0), true);
  assert.equal(badge.text.textContent, "Sincronizado com o anfitrião");
});
