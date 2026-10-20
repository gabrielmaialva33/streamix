import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { AVPLAYER_CONFIG } from "../media/config.js";

// The vendored libmedia bundle carries one Streamix patch; losing it on a
// re-vendor silently brings back "embedded subtitles never show".
test("the served libmedia subtitle renderer unserializes worker packets", () => {
  const dir = new URL(`../../../priv/static${AVPLAYER_CONFIG.scriptBasePath}/`, import.meta.url);
  const chunk = readFileSync(new URL("168.avplayer.js", dir), "utf8");

  assert.match(chunk, /streamixPacket=s\(10567\)/);
  assert.match(chunk, /"object"==typeof t&&\(t=\(0,streamixPacket\.r0\)\(t,/);
  assert.ok(readFileSync(new URL("avplayer.js", dir), "utf8").includes("10567:(e,t,i)=>"));
});
