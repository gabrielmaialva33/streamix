import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const avPlayerActivationUrl = new URL("../player/avplayer_engine_activation.js", import.meta.url);

async function hookSource() {
  return readFile(hookUrl, "utf8");
}

async function avPlayerActivationSource() {
  return readFile(avPlayerActivationUrl, "utf8");
}

test("advanced engines are visible to the orchestrator without transferring ownership", async () => {
  const source = await hookSource();

  assert.match(source, /trackManagedEngine\(engineId, engine\) \{[\s\S]*registryOwnsEngine: false/);
  assert.match(source, /trackManagedEngine\(ENGINE_ID\.AVBRIDGE, this\.avbridge\);/);
  assert.match(source, /trackManagedEngine\(ENGINE_ID\.H265WEB, this\.h265web\);/);
  assert.match(
    await avPlayerActivationSource(),
    /this\.host\.trackManagedEngine\(ENGINE_ID\.AVPLAYER, engine\);/,
  );
  assert.match(
    source,
    /trackManagedEngine: \(engineId, engine\) => this\.trackManagedEngine\(engineId, engine\)/,
  );
});

test("the hook still owns advanced-engine teardown", async () => {
  const source = await hookSource();

  assert.match(source, /teardownAVPlayer\(/);
  assert.match(source, /this\.avbridge/);
  assert.match(source, /this\.h265web/);
  assert.doesNotMatch(source, /trackManagedEngine\([^)]*\)[\s\S]{0,120}registryOwnsEngine: true/);
});
