import assert from "node:assert/strict";
import test from "node:test";

import {
  hasPlayableSubtitleTimeBase,
  initialAVPlayerPlayOptions,
} from "../player/subtitle_policy.js";

test("starts AVPlayer with subtitles disabled until the user selects a track", () => {
  assert.deepEqual(initialAVPlayerPlayOptions(), {
    video: true,
    audio: true,
    subtitle: false,
  });
});

test("rejects subtitle streams whose time-base would divide by zero", () => {
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 1, den: 1_000 } }), true);
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 0, den: 1_000 } }), false);
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 1, den: 0 } }), false);
  assert.equal(hasPlayableSubtitleTimeBase({}), true);
});
