import assert from "node:assert/strict";
import test from "node:test";
import Modal from "../hooks/modal.js";

function fixture(t, dataset = {}) {
  const old = global.document;
  const trigger = { isConnected: true, focus: () => (document.activeElement = trigger) };
  const field = { focus: () => (document.activeElement = field) };
  const closeButton = { focus: () => (document.activeElement = closeButton) };
  const events = new Map();
  global.document = {
    activeElement: {},
    querySelector: (selector) => (selector === "#trigger" ? trigger : null),
    addEventListener() {},
    removeEventListener() {},
  };
  t.after(() => {
    global.document = old;
  });
  const sent = [];
  const hook = {
    ...Modal,
    pushEvent: (name) => sent.push(name),
    el: {
      dataset: { show: "true", returnFocus: "#trigger", ...dataset },
      open: false,
      showModal() {
        this.open = true;
      },
      close() {
        this.open = false;
        events.get("close")?.();
      },
      querySelector: (selector) => (selector.startsWith("input") ? field : closeButton),
      addEventListener: (name, fn) => events.set(name, fn),
      removeEventListener: (name) => events.delete(name),
    },
  };
  return { hook, field, trigger, sent };
}

test("modal initially focuses the form and restores the explicit trigger on Escape", (t) => {
  const { hook, field, trigger, sent } = fixture(t);
  hook.mounted();
  assert.equal(document.activeElement, field);
  hook.handleKeyDown({ key: "Escape", preventDefault() {} });
  assert.equal(document.activeElement, trigger);
  assert.deepEqual(sent, ["close_modal"]);
  hook.destroyed();
});

test("gallery modal sends its own close event and restores after removal", (t) => {
  const { hook, trigger, sent } = fixture(t, { closeEvent: "close_gallery_preview" });
  hook.mounted();
  hook.el.close();
  assert.deepEqual(sent, ["close_gallery_preview"]);
  hook.destroyed();
  assert.equal(document.activeElement, trigger);
});
