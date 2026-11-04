import assert from "node:assert/strict";
import test from "node:test";
import { PlayerUI } from "../player/player_ui.js";

function element() {
  const classes = new Set();
  return {
    classList: {
      add: (...names) =>
        names.forEach((name) => {
          classes.add(name);
        }),
      remove: (...names) =>
        names.forEach((name) => {
          classes.delete(name);
        }),
      contains: (name) => classes.has(name),
    },
    appendChild() {},
    remove() {
      this.removed = true;
    },
  };
}
function harness(t) {
  const nodes = new Map(
    [
      "#resume-toast",
      "#resume-time-text",
      "#resume-restart-btn",
      "#ended-overlay",
      "#ended-replay-btn",
      "#ended-back-btn",
    ].map((id) => [id, element()]),
  );
  const container = {
    querySelector: (id) => nodes.get(id) || null,
    appendChild: (node) => nodes.set(".quality-toast", node),
  };
  const previousDocument = globalThis.document;
  globalThis.document = { createElement: element };
  t.after(() => {
    if (previousDocument === undefined) delete globalThis.document;
    else globalThis.document = previousDocument;
  });
  return { ui: new PlayerUI(container), nodes };
}

test("replacing a quality toast and destroying UI releases every overlay timer", (t) => {
  const pending = new Map();
  let id = 0;
  t.mock.method(globalThis, "setTimeout", (fn) => {
    pending.set(++id, fn);
    return id;
  });
  t.mock.method(globalThis, "clearTimeout", (key) => pending.delete(key));
  const { ui, nodes } = harness(t);
  ui.showQualityChange("720p");
  const oldToast = nodes.get(".quality-toast");
  ui.showQualityChange("1080p");
  assert.equal(oldToast.removed, true);
  assert.equal(pending.size, 1, "replacement must release the previous animation timer");
  ui.showResumeToast(90, () => {});
  ui.hideResumeToast();
  ui.destroy();
  assert.equal(pending.size, 0, "destroy must cancel the resume exit and quality timers");
  assert.equal(nodes.get(".quality-toast").removed, true);
  assert.equal(nodes.get("#resume-restart-btn").onclick, null);
  ui.destroy();
});

test("a resume toast reopened during its exit cannot be hidden by the old timer", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { ui, nodes } = harness(t);
  ui.showResumeToast(60, () => {});
  ui.hideResumeToast();
  ui.showResumeToast(90, () => {});
  t.mock.timers.tick(300);
  assert.equal(nodes.get("#resume-toast").classList.contains("hidden"), false);
  t.mock.timers.tick(4700);
  t.mock.timers.tick(300);
  assert.equal(nodes.get("#resume-toast").classList.contains("hidden"), true);
  ui.destroy();
});

test("destroy cancels a pending resume animation frame and releases action handlers", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const frames = new Map();
  const previousRequest = globalThis.requestAnimationFrame;
  const previousCancel = globalThis.cancelAnimationFrame;
  globalThis.requestAnimationFrame = (callback) => {
    frames.set(1, callback);
    return 1;
  };
  globalThis.cancelAnimationFrame = (id) => frames.delete(id);
  t.after(() => {
    if (previousRequest === undefined) delete globalThis.requestAnimationFrame;
    else globalThis.requestAnimationFrame = previousRequest;
    if (previousCancel === undefined) delete globalThis.cancelAnimationFrame;
    else globalThis.cancelAnimationFrame = previousCancel;
  });
  const { ui, nodes } = harness(t);
  ui.showResumeToast(90, () => {});
  ui.showEndedOverlay(
    () => {},
    () => {},
  );
  assert.equal(frames.size, 1);
  ui.destroy();
  assert.equal(frames.size, 0);
  for (const id of ["#resume-restart-btn", "#ended-replay-btn", "#ended-back-btn"]) {
    assert.equal(nodes.get(id).onclick, null);
  }
});
