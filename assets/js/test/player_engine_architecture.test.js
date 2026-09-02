import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function source(relativePath) {
  return readFile(new URL(relativePath, import.meta.url), "utf8");
}

test("the adapter consumes the centralized engine contract", async () => {
  const adapter = await source("../player/playback_engine_adapter.js");

  assert.match(adapter, /assertPlaybackEngine[\s\S]*from "\.\/engine_contract\.js"/);
  assert.match(adapter, /assertPlaybackEngine\(engine, \{ name: "PlaybackEngineAdapter" \}\)/);
  assert.doesNotMatch(adapter, /const REQUIRED_METHODS/);
  assert.doesNotMatch(adapter, /function assertEngine/);
});

test("media element engines validate through the same contract", async () => {
  const mediaElement = await source("../player/media_element_engine.js");
  const native = await source("../player/native_playback_engine.js");
  const hls = await source("../player/hls_playback_engine.js");
  const avplayer = await source("../player/avplayer_playback_engine.js");

  assert.match(mediaElement, /assertPlaybackEngine\(new MediaElementEngine\(options\)/);
  assert.match(native, /assertPlaybackEngine\(new NativePlaybackEngine\(options\)/);
  assert.match(hls, /assertPlaybackEngine\(new HlsPlaybackEngine\(options\)/);
  assert.match(avplayer, /assertPlaybackEngine\(new AvPlayerPlaybackEngine\(options\)/);
  assert.match(avplayer, /new Wrapper\(\{[\s\S]*onReady:[\s\S]*onError:/);
  assert.match(
    avplayer,
    /this\.emit\(ENGINE_EVENT\.(READY|PLAYING|PAUSED|TIME_UPDATE|ENDED|ERROR)/,
  );
});

test("concrete engines remain independent from the Phoenix hook", async () => {
  for (const relativePath of [
    "../player/native_playback_engine.js",
    "../player/hls_playback_engine.js",
    "../player/avplayer_playback_engine.js",
  ]) {
    const engine = await source(relativePath);

    assert.doesNotMatch(engine, /hooks\/video_player/);
    assert.doesNotMatch(engine, /pushEvent|LiveSocket|Phoenix/);
  }
});

test("StreamLoader owns HLS transport while the HLS activation borrows its engine contract", async () => {
  const loader = await source("../media/stream_loader.js");
  const hook = await source("../hooks/video_player.js");
  const activation = await source("../player/hls_engine_activation.js");

  assert.match(loader, /createHlsPlaybackEngine/);
  assert.match(loader, /this\.hlsEngine = hlsEngine/);
  assert.match(loader, /getHlsEngine\(\)/);
  assert.match(loader, /hlsEngine\.load\(url\)/);
  assert.match(loader, /this\.hlsEngine\.reload\(url\)/);

  assert.match(activation, /adoptLoaderEngine\(/);
  assert.match(activation, /const hlsEngine = loader\.getHlsEngine\?\.\(\)/);
  assert.match(activation, /this\.host\.registerMediaElementEngine\(ENGINE_ID\.HLS, hlsEngine\)/);
  assert.doesNotMatch(activation, /new Hls\(|createHlsPlaybackEngine\(/);

  assert.match(hook, /activateHlsEngineFromLoader\(/);
  assert.match(hook, /\?\.adoptLoaderEngine\(sessionId, loader\)/);
  assert.match(hook, /setMediaElementEngine\(engineId, engine, \{ ownsEngine = false \} = \{\}\)/);
  assert.doesNotMatch(hook, /loader\.getHlsEngine|new Hls\(/);
});
