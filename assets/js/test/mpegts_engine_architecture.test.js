import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const streamLoaderUrl = new URL("../media/stream_loader.js", import.meta.url);
const videoPlayerUrl = new URL("../hooks/video_player.js", import.meta.url);
const engineUrl = new URL("../player/mpegts_playback_engine.js", import.meta.url);
const activationUrl = new URL("../player/mpegts_engine_activation.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("StreamLoader creates and owns the MPEG-TS playback engine", async () => {
  const loader = await source(streamLoaderUrl);

  assert.match(
    loader,
    /import \{ createMpegtsPlaybackEngine \} from "\.\.\/player\/mpegts_playback_engine\.js";/,
  );
  assert.match(loader, /this\.mpegtsEngine = null;/);
  assert.match(loader, /const engine = createMpegtsPlaybackEngine\(\{/);
  assert.match(loader, /this\.mpegtsEngine = engine;/);
  assert.match(loader, /engine\.load\(\{ url, type \}\);/);
  assert.match(loader, /getMpegtsEngine\(\) \{\s*return this\.mpegtsEngine;/);
  assert.match(
    loader,
    /const engine = this\.mpegtsEngine;[\s\S]*this\.mpegtsEngine = null;[\s\S]*engine\.destroy\(\);/,
  );
});

test("the MPEG-TS activation borrows the engine without owning transport teardown", async () => {
  const hook = await source(videoPlayerUrl);
  const activation = await source(activationUrl);

  assert.match(activation, /const mpegtsEngine = loader\.getMpegtsEngine\(\);/);
  assert.match(
    activation,
    /this\.host\.registerMediaElementEngine\(ENGINE_ID\.MPEGTS, mpegtsEngine\);/,
  );
  assert.doesNotMatch(activation, /new MpegtsPlaybackEngine\(|createMpegtsPlaybackEngine\(/);

  assert.doesNotMatch(hook, /getMpegtsEngine\(\)/);
  assert.doesNotMatch(hook, /new MpegtsPlaybackEngine\(/);
  assert.doesNotMatch(hook, /createMpegtsPlaybackEngine\(/);
});

test("MpegtsPlaybackEngine stays independent of Phoenix and the main hook", async () => {
  const engine = await source(engineUrl);

  assert.doesNotMatch(engine, /phoenix|liveview|video_player/i);
  assert.match(engine, /assertPlaybackEngine/);
  assert.match(engine, /attachMediaElement/);
  assert.match(engine, /player\.unload\(\)/);
  assert.match(engine, /player\.destroy\(\)/);
});
