import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const component = readFileSync(
  new URL(
    "../../../lib/streamix_web/components/content/source_picker_components.ex",
    import.meta.url,
  ),
  "utf8",
);
const script = component.match(
  /<script :type=\{Phoenix.LiveView.ColocatedHook\} name="\.SourcePicker">([\s\S]*?)<\/script>/,
)[1];
const { default: hook } = await import(`data:text/javascript,${encodeURIComponent(script)}`);

test("source radio arrows select and focus adjacent options, wrapping both ways", () => {
  const actions = [];
  const options = [0, 1, 2].map((id) => ({
    closest: () => options[id],
    focus: () => actions.push(["focus", id]),
    click: () => actions.push(["click", id]),
  }));
  const listeners = new Map();
  const context = {
    el: {
      querySelectorAll: () => options,
      addEventListener: (name, fn) => listeners.set(name, fn),
      removeEventListener: (name, fn) => {
        assert.equal(listeners.get(name), fn);
        listeners.delete(name);
      },
    },
  };
  hook.mounted.call(context);
  for (const [key, from, to] of [
    ["ArrowRight", 2, 0],
    ["ArrowLeft", 0, 2],
    ["ArrowDown", 0, 1],
    ["ArrowUp", 2, 1],
  ]) {
    let prevented = false;
    listeners.get("keydown")({
      key,
      target: options[from],
      preventDefault: () => {
        prevented = true;
      },
    });
    assert.ok(prevented);
    assert.deepEqual(actions.splice(0), [
      ["focus", to],
      ["click", to],
    ]);
  }
  listeners.get("keydown")({ key: "Tab" });
  assert.deepEqual(actions, []);
  hook.destroyed.call(context);
  assert.equal(listeners.size, 0);
});
