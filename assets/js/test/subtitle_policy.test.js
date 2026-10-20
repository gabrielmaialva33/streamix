import assert from "node:assert/strict";
import test from "node:test";

import {
  hasPlayableSubtitleTimeBase,
  initialAVPlayerPlayOptions,
} from "../player/subtitle_policy.js";

const subtitle = (timeBase) => ({ mediaType: "Subtitle", timeBase });
const audio = { mediaType: "Audio", timeBase: { num: 0, den: 0 } };

test("starts the AVPlayer subtitle renderer only when every subtitle stream can run it", () => {
  const options = (streams) => initialAVPlayerPlayOptions(streams).subtitle;

  // No subtitle stream: nothing to render.
  assert.deepEqual(initialAVPlayerPlayOptions(), { video: true, audio: true, subtitle: false });
  assert.equal(options([audio]), false);
  // The renderer must start in play() for any embedded subtitle to work later.
  assert.equal(options([audio, subtitle({ num: 1, den: 1_000 }), subtitle(undefined)]), true);
  // One zero time-base stream would crash it.
  assert.equal(
    options([subtitle({ num: 1, den: 1_000 }), subtitle({ num: 0, den: 1_000 })]),
    false,
  );
});

test("rejects subtitle streams whose time-base would divide by zero", () => {
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 1, den: 1_000 } }), true);
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 0, den: 1_000 } }), false);
  assert.equal(hasPlayableSubtitleTimeBase({ timeBase: { num: 1, den: 0 } }), false);
  assert.equal(hasPlayableSubtitleTimeBase({}), true);
});
