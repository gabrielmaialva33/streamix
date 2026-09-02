import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const transportUrl = new URL("../player/stream_transport.js", import.meta.url);
const playerStateUrl = new URL("../player/player_state.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("the StreamTransport owns the loader lifecycle behind an explicit host", async () => {
  const transport = await source(transportUrl);

  assert.match(transport, /export class StreamTransport/);
  assert.match(transport, /STREAM_TRANSPORT_HOST_METHODS = Object\.freeze\(\[/);
  assert.match(transport, /assertActivationHost\(host, STREAM_TRANSPORT_HOST_METHODS/);
  assert.match(transport, /createStreamLoader: \(options\) => new StreamLoader\(options\)/);
  for (const callback of [
    "onManifestParsed",
    "onError",
    "onLevelSwitched",
    "onAudioTracksUpdated",
    "onSubtitleTracksUpdated",
    "onFragLoaded",
    "onMediaInfo",
    "onStatisticsInfo",
  ]) {
    assert.match(transport, new RegExp(`${callback}: \\(`), `transport must wire ${callback}`);
  }
  assert.doesNotMatch(
    transport,
    /hooks\/video_player|pushEventSafe|LiveSocket|Phoenix|document\.|window\./,
  );
});

test("the player hook composes the transport and no longer constructs or tears down loaders", async () => {
  const [hook, playerState] = await Promise.all([source(hookUrl), source(playerStateUrl)]);

  assert.match(
    hook,
    /import \{ createStreamTransport \} from "\.\.\/player\/stream_transport\.js";/,
  );
  assert.match(
    hook,
    /this\.streamTransport = createStreamTransport\(\{ host: this\.buildStreamTransportHost\(\) \}\);/,
  );
  assert.match(hook, /ensureStreamLoader\(\) \{\s*return this\.streamTransport\.ensure\(\);/);
  assert.match(
    hook,
    /hlsRecoveryContext\(\) \{\s*return this\.streamTransport\.recoveryContext\(\{/,
  );
  assert.match(hook, /await this\.streamTransport\.awaitTeardown\(\);/);
  assert.match(hook, /void this\.streamTransport\?\.teardown\(\);/);
  assert.match(
    hook,
    /_definePlayerAccessors\(\) \{[\s\S]*Object\.defineProperty\(this, "streamLoader"/,
  );

  for (const leaked of [
    "new StreamLoader(",
    "onManifestParsed:",
    "onLevelSwitched:",
    "onFragLoaded:",
    "onStatisticsInfo:",
    "_streamLoaderTeardownPromise",
    "this.streamLoader = ",
    "streamLoader.destroy()",
    "updateSessionId(",
  ]) {
    assert.equal(hook.includes(leaked), false, `${leaked} must live in StreamTransport`);
  }

  assert.doesNotMatch(
    hook,
    /^\s{2}(?:get|set) \w+\(/m,
    "hook object literals must not declare accessors: LiveView copies them as static values",
  );

  assert.match(playerState, /streamTransport: null/);
  assert.doesNotMatch(playerState, /streamLoader: null|_streamLoaderTeardownPromise/);
});
