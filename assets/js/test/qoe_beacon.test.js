import assert from "node:assert/strict";
import test from "node:test";

import { QOE_BEACON_PATH, sendQoeBeacon } from "../telemetry/qoe_beacon.js";

const documentWithToken = (token) => ({
  querySelector: (selector) =>
    selector === 'meta[name="csrf-token"]' && token ? { content: token } : null,
});

test("a finished session goes out as a beacon carrying the CSRF token", async () => {
  const sent = [];
  const navigatorRef = { sendBeacon: (path, body) => sent.push({ path, body }) > 0 };

  assert.equal(
    sendQoeBeacon(
      { batch_id: "b-1", event: "playback_session" },
      { navigatorRef, documentRef: documentWithToken("tok") },
    ),
    true,
  );

  assert.equal(sent.length, 1);
  assert.equal(sent[0].path, QOE_BEACON_PATH);
  assert.equal(sent[0].body.type, "application/json");
  assert.deepEqual(JSON.parse(await sent[0].body.text()), {
    batch_id: "b-1",
    event: "playback_session",
    _csrf_token: "tok",
  });
});

test("nothing is sent without a sample, a token or sendBeacon", () => {
  const navigatorRef = {
    sendBeacon: () => {
      throw new Error("must not be called");
    },
  };

  assert.equal(sendQoeBeacon(null, { navigatorRef, documentRef: documentWithToken("tok") }), false);
  assert.equal(
    sendQoeBeacon({ batch_id: "b" }, { navigatorRef, documentRef: documentWithToken(null) }),
    false,
  );
  assert.equal(
    sendQoeBeacon({ batch_id: "b" }, { navigatorRef: {}, documentRef: documentWithToken("tok") }),
    false,
  );
});
