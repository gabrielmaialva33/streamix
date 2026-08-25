import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);

async function hookSource() {
  return readFile(hookUrl, "utf8");
}

test("defines the Media Capabilities preparation invoked during mount", async () => {
  const source = await hookSource();

  assert.match(source, /async prepareMediaCapabilityProfile\(\)\s*\{/);
  assert.match(
    source,
    /configurationFromPlayerElement\(\s*this\.el,\s*this\.currentStreamType,?\s*\)/,
  );
  assert.match(source, /this\.mediaCapabilityProfile = await probeMediaCapability\(\{/);
  assert.match(source, /decodingInfo: getMediaDecodingInfo/);
  assert.match(source, /timeoutMs: 250/);
});

test("keeps capability probing bounded and non-fatal before player initialization", async () => {
  const source = await hookSource();
  const mountedProbe = source.indexOf("this.prepareMediaCapabilityProfile()");
  const mountedInit = source.indexOf("this.initPlayer();", mountedProbe);
  const methodStart = source.indexOf("async prepareMediaCapabilityProfile()");
  const methodEnd = source.indexOf("\n  buildEngineContext(", methodStart);
  const method = source.slice(methodStart, methodEnd);

  assert.ok(mountedProbe >= 0);
  assert.ok(mountedInit > mountedProbe);
  assert.match(method, /catch \(error\)/);
  assert.match(method, /this\.mediaCapabilityProfile = null/);
  assert.match(method, /return this\.mediaCapabilityProfile/);
  assert.doesNotMatch(method, /navigator\.mediaCapabilities/);
});
