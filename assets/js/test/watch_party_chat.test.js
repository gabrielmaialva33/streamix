import assert from "node:assert/strict";
import test from "node:test";

import WatchPartyChat from "../hooks/watch_party_chat.js";

test("traps focus only while the chat is a mobile bottom sheet", () => {
  const calls = [];
  const context = Object.assign(Object.create(WatchPartyChat), {
    focusTrap: {
      activate: () => calls.push("activate"),
      deactivate: () => calls.push("deactivate"),
    },
    mobileQuery: { matches: true },
  });

  context.syncFocusTrap();
  context.mobileQuery.matches = false;
  context.syncFocusTrap();

  assert.deepEqual(calls, ["activate", "deactivate"]);
});

test("keeps chat pinned to the bottom only when the reader was already nearby", () => {
  const messages = {
    clientHeight: 300,
    scrollHeight: 1_000,
    scrollTop: 590,
  };
  const context = Object.assign(Object.create(WatchPartyChat), {
    el: {
      querySelector(selector) {
        return selector === "#wp-chat-messages" ? messages : null;
      },
    },
    messages,
    wasNearBottom: false,
  });

  assert.equal(context.isNearBottom(), true);
  context.beforeUpdate();
  context.updated();
  assert.equal(messages.scrollTop, 1_000);

  messages.scrollTop = 100;
  context.beforeUpdate();
  context.updated();
  assert.equal(messages.scrollTop, 100);
});

test("scrollToBottom uses an immediate position during initial mount", () => {
  const messages = { scrollHeight: 420, scrollTop: 0 };
  const context = Object.assign(Object.create(WatchPartyChat), { messages });

  context.scrollToBottom();

  assert.equal(messages.scrollTop, 420);
});
