import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

test("detached card preview retains the provider for its play button's intent and engine warmup", () => {
  const source = readFileSync(new URL("../hooks/content_card.js", import.meta.url), "utf8")
    .replace(/^import[^;]+;\n/gm, "")
    .replace("export default ContentCard;", "globalThis.hook = ContentCard;");
  let appended;
  const preview = {
    dataset: {},
    style: {},
    getBoundingClientRect: () => ({ width: 200, height: 100 }),
    addEventListener() {},
  };
  const context = {
    window: { __contentCardGlobalListenersBound: true, innerWidth: 1024, innerHeight: 768 },
    document: {
      createElement: () => preview,
      body: {
        appendChild: (node) => {
          appended = node;
        },
      },
    },
    requestAnimationFrame: (callback) => callback(),
  };
  vm.runInNewContext(source, context);
  const hook = Object.assign({}, context.hook, {
    title: "Synthetic",
    contentId: "42",
    providerId: "3",
    sourceType: "xtream",
    el: {
      dataset: { streamType: "mp4" },
      getBoundingClientRect: () => ({ width: 200, left: 300, top: 300, bottom: 400 }),
    },
    _closePreview() {},
    buildPreviewHTML: () => "",
    bindPreviewActions() {},
  });
  hook.showPreview();
  assert.equal(appended, preview);
  assert.equal(preview.dataset.providerId, "3");
  assert.equal(preview.dataset.contentId, "42");
  assert.equal(preview.dataset.streamType, "mp4");
});
