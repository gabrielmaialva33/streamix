import assert from "node:assert/strict";
import test from "node:test";

import { selectEngine } from "../player/engine_selector.js";

const cases = [
  {
    name: "uses GPU HEVC engine for supported UHD VOD",
    context: {
      streamType: "mkv",
      isUhdHevc: true,
      capabilities: { avbridge: true },
    },
    expected: "avbridge",
  },
  {
    name: "honors a proven AVPlayer recommendation",
    context: { streamType: "mp4", recommendedPlayer: "avplayer" },
    expected: "avplayer",
  },
  {
    name: "prefers native HLS when the platform supports it",
    context: {
      streamType: "hls",
      capabilities: { nativeHls: true, hlsJs: true },
    },
    expected: "native",
  },
  {
    name: "uses hls.js for HLS outside native Safari",
    context: { streamType: "hls", capabilities: { hlsJs: true } },
    expected: "hls-js",
  },
  {
    name: "uses mpegts for live transport streams",
    context: { streamType: "xtream", capabilities: { mpegts: true } },
    expected: "mpegts",
  },
  {
    name: "reports unsupported FLV instead of pretending native can play it",
    context: { streamType: "flv", capabilities: {} },
    expected: "flv-unsupported",
  },
];

for (const { name, context, expected } of cases) {
  test(name, () => {
    assert.equal(selectEngine(context), expected);
  });
}
