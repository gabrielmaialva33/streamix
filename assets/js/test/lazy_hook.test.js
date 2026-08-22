import assert from "node:assert/strict";
import test from "node:test";

import { createLazyHook } from "../core/lazy_hook.js";

test("loads a hook only when its element mounts and preserves custom methods", async () => {
  let loadCount = 0;
  const lifecycle = [];
  const hook = createLazyHook("VideoPlayer", async () => {
    loadCount += 1;

    return {
      default: {
        mounted() {
          lifecycle.push(this.describe());
        },
        updated() {
          lifecycle.push("updated");
        },
        describe() {
          return `mounted:${this.el.id}`;
        },
      },
    };
  });
  const context = { el: { id: "player", dataset: {} } };

  assert.equal(loadCount, 0);
  await hook.mounted.call(context);
  hook.updated.call(context);

  assert.equal(loadCount, 1);
  assert.deepEqual(lifecycle, ["mounted:player", "updated"]);
});

test("does not mount a lazy implementation after its element was destroyed", async () => {
  let resolveModule;
  let mounted = false;
  const hook = createLazyHook(
    "VideoPlayer",
    () =>
      new Promise((resolve) => {
        resolveModule = resolve;
      }),
  );
  const context = { el: { id: "player", dataset: {} } };

  const mounting = hook.mounted.call(context);
  hook.destroyed.call(context);
  resolveModule({ default: { mounted: () => (mounted = true) } });
  await mounting;

  assert.equal(mounted, false);
});

test("skips route-specific code when the mount environment does not need it", async () => {
  let loadCount = 0;
  const hook = createLazyHook(
    "ContentCard",
    async () => {
      loadCount += 1;
      return { default: { mounted() {} } };
    },
    {
      shouldLoad: (context) => context.el.dataset.hoverPreview === "true",
    },
  );
  const context = { el: { dataset: { hoverPreview: "false" } } };

  await hook.mounted.call(context);
  hook.updated.call(context);
  hook.destroyed.call(context);

  assert.equal(loadCount, 0);
  assert.equal(context.el.dataset.lazyHookError, undefined);
});
