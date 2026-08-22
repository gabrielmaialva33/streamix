import assert from "node:assert/strict";
import test from "node:test";

import {
  automaticLoadLimit,
  automaticPreloadMargin,
  infiniteScrollStateKey,
  parseInfiniteScrollPage,
} from "../hooks/infinite_scroll_policy.js";

test("uses a small automatic page budget and tightens it on constrained devices", () => {
  assert.equal(
    automaticLoadLimit({
      navigatorRef: {
        connection: { saveData: false, effectiveType: "4g" },
        deviceMemory: 8,
        hardwareConcurrency: 8,
      },
    }),
    2,
  );
  assert.equal(
    automaticLoadLimit({
      navigatorRef: {
        connection: { saveData: true, effectiveType: "4g" },
        deviceMemory: 8,
        hardwareConcurrency: 8,
      },
    }),
    1,
  );
  assert.equal(automaticLoadLimit({ configured: "0", navigatorRef: {} }), 0);
  assert.equal(automaticLoadLimit({ configured: "99", navigatorRef: {} }), 10);
});

test("uses a smaller preload margin when speculative work should be avoided", () => {
  assert.equal(
    automaticPreloadMargin({
      connection: { effectiveType: "2g" },
      deviceMemory: 8,
      hardwareConcurrency: 8,
    }),
    300,
  );
  assert.equal(
    automaticPreloadMargin({
      connection: { effectiveType: "4g" },
      deviceMemory: 8,
      hardwareConcurrency: 8,
    }),
    800,
  );
});

test("keeps automatic-load state stable while only the page query changes", () => {
  const first = infiniteScrollStateKey({
    elementId: "movies-sentinel",
    locationRef: { href: "https://streamix.test/browse/movies?provider=7&page=2" },
  });
  const second = infiniteScrollStateKey({
    elementId: "movies-sentinel",
    locationRef: { href: "https://streamix.test/browse/movies?provider=7&page=9" },
  });
  const filtered = infiniteScrollStateKey({
    elementId: "movies-sentinel",
    locationRef: { href: "https://streamix.test/browse/movies?provider=8&page=9" },
  });

  assert.equal(first, second);
  assert.notEqual(second, filtered);
});

test("normalizes zero-based and malformed page values", () => {
  assert.equal(parseInfiniteScrollPage("0"), 0);
  assert.equal(parseInfiniteScrollPage("12"), 12);
  assert.equal(parseInfiniteScrollPage("-1", 4), 4);
  assert.equal(parseInfiniteScrollPage("invalid", 3), 3);
});
