import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// The autoplay-blocked button and the end-of-title replay call this.play()
// on the hook. It once went missing in a refactor and both buttons threw
// "this.play is not a function" while every callback test still passed.
test("the player hook exposes every method its own callbacks call on it", () => {
  const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
  const sources = [
    read("../hooks/video_player.js"),
    read("../player/player_composition.js"),
    read("../player/player_session_lifecycle.js"),
  ].join("\n");

  for (const method of ["play", "seekTo", "togglePlayPause"]) {
    assert.match(sources, new RegExp(`\\n  (async )?${method}\\(`), `missing ${method}()`);
  }
});
