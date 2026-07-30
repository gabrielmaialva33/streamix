import assert from "node:assert/strict";
import test from "node:test";

import {
  nextEpisodeCountdownWidth,
  nextEpisodePath,
  parseNextEpisode,
  shouldTriggerNextEpisode,
} from "../player/next_episode.js";

test("parses only serialized object payloads", () => {
  assert.deepEqual(parseNextEpisode('{"id":42,"type":"episode"}'), {
    id: 42,
    type: "episode",
  });
  assert.equal(parseNextEpisode("broken"), null);
  assert.equal(parseNextEpisode("[]"), null);
});

test("triggers at thirty seconds remaining or ninety percent complete", () => {
  assert.equal(shouldTriggerNextEpisode(69, 100), false);
  assert.equal(shouldTriggerNextEpisode(70, 100), true);
  assert.equal(shouldTriggerNextEpisode(90, 200), false);
  assert.equal(shouldTriggerNextEpisode(180, 200), true);
  assert.equal(shouldTriggerNextEpisode(10, 0), false);
});

test("builds a whitelisted path and rejects non-numeric ids", () => {
  assert.equal(nextEpisodePath({ type: "movie", id: "42" }), "/watch/movie/42");
  assert.equal(nextEpisodePath({ type: "series", id: 42 }), "/watch/episode/42");
  assert.equal(nextEpisodePath({ type: "episode", id: "42/../../admin" }), null);
  assert.equal(nextEpisodePath({ type: "episode", id: 0 }), null);
});

test("clamps countdown width to its valid range", () => {
  assert.equal(nextEpisodeCountdownWidth(7), 70);
  assert.equal(nextEpisodeCountdownWidth(20), 100);
  assert.equal(nextEpisodeCountdownWidth(-1), 0);
});
