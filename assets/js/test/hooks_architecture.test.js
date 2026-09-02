import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

const hooksDirUrl = new URL("../hooks/", import.meta.url);

async function hookSources() {
  const names = (await readdir(hooksDirUrl)).filter((name) => name.endsWith(".js")).sort();
  const sources = await Promise.all(
    names.map((name) => readFile(new URL(name, hooksDirUrl), "utf8")),
  );
  return names
    .map((name, index) => [name, sources[index]])
    .filter(([, text]) => /^\s{2}mounted\(/m.test(text));
}

test("LiveView hook objects never declare accessors, which the runtime would freeze into values", async () => {
  const hooks = await hookSources();
  assert.ok(hooks.length >= 10, "expected the hook directory to be scanned");

  for (const [name, text] of hooks) {
    assert.doesNotMatch(
      text,
      /^\s{2}(?:get|set) \w+\(/m,
      `${name}: define live accessors on the instance (Object.defineProperty in mounted/_setup), not on the hook object`,
    );
  }
});

test("hooks compose media engines through controllers instead of constructing them", async () => {
  for (const [name, text] of await hookSources()) {
    assert.doesNotMatch(
      text,
      /new (?:\w+Wrapper|StreamLoader|\w+PlaybackEngine|Hls|Mpegts\w*|NativeBufferManager)\(/,
      `${name} must not construct concrete media engines`,
    );
  }
});

test("the player hook keeps network access behind controllers", async () => {
  const player = await readFile(new URL("../hooks/video_player.js", import.meta.url), "utf8");
  assert.doesNotMatch(player, /\bfetch\(/);
  assert.doesNotMatch(player, /\/api\/gindex-tracks/);
});
