import assert from "node:assert/strict";
import test from "node:test";

import {
  buildQualityMediaConfig,
  buildQualityProbeCandidates,
  detectQualityCodec,
  qualityVideoCodec,
} from "../lib/quality_probe.js";

test("normalizes common manifest codec families", () => {
  assert.equal(detectQualityCodec({ codecs: "av01.0.08M.08" }), "av1");
  assert.equal(detectQualityCodec({ videoCodec: "hvc1.1.6.L120" }), "hevc");
  assert.equal(detectQualityCodec({ codecs: "vp09.00.41.08" }), "vp9");
  assert.equal(detectQualityCodec({ codecs: "mp4a.40.2, avc1.640028" }), "h264");
  assert.equal(detectQualityCodec({ codecs: "theora" }), "unknown");
});

test("extracts the video codec and builds MediaCapabilities input", () => {
  const quality = {
    codecs: 'mp4a.40.2, "avc1.640028"',
    width: 1920,
    height: 1080,
    bitrate: 5_000_000,
    frameRate: "60",
  };

  assert.equal(qualityVideoCodec(quality), "avc1.640028");
  assert.deepEqual(buildQualityMediaConfig(quality), {
    type: "media-source",
    video: {
      contentType: 'video/mp4; codecs="avc1.640028"',
      width: 1920,
      height: 1080,
      bitrate: 5_000_000,
      framerate: 60,
    },
  });
});

test("filters incomplete qualities and caps probe work", () => {
  const valid = {
    codecs: "vp09.00.41.08",
    width: 1280,
    height: 720,
    bitrate: 2_000_000,
  };

  assert.equal(buildQualityMediaConfig({ codecs: "avc1.640028" }), null);
  assert.equal(buildQualityProbeCandidates([{ label: "audio-only" }, valid], 1).length, 1);
});
