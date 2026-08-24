import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function source(relativePath) {
  return readFile(new URL(relativePath, import.meta.url), "utf8");
}

test("the adapter consumes the centralized engine contract", async () => {
  const adapter = await source("../player/playback_engine_adapter.js");

  assert.match(adapter, /assertPlaybackEngine[\s\S]+from "\.\/engine_contract\.js"/);
  assert.match(adapter, /assertPlaybackEngine\(engine, \{ name: "PlaybackEngineAdapter" \}\)/);
  assert.doesNotMatch(adapter, /const REQUIRED_METHODS/);
  assert.doesNotMatch(adapter, /function assertEngine/);
});

test("media-element engines validate through the same contract", async () => {
  const mediaElement = await source("../player/media_element_engine.js");
  const native = await source("../player/native_playback_engine.js");

  assert.match(mediaElement, /assertPlaybackEngine\(new MediaElementEngine\(options\)/);
  assert.match(native, /createMediaElementEngine/);
  assert.match(native, /assertPlaybackEngine\(new NativePlaybackEngine\(options\)/);
});

test("the native engine remains independent from the Phoenix hook", async () => {
  const native = await source("../player/native_playback_engine.js");

  assert.doesNotMatch(native, /hooks\/video_player/);
  assert.doesNotMatch(native, /pushEvent|LiveSocket|Phoenix/);
  assert.match(native, /ENGINE_ID\.NATIVE/);
});
