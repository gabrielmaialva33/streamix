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
    name: "prefers native HLS on Apple WebKit",
    context: {
      streamType: "hls",
      recommendedPlayer: "avplayer",
      preferNativeHls: true,
      capabilities: { nativeHls: true, hlsJs: true },
    },
    expected: "native",
  },
  {
    name: "uses hls.js outside Apple even when canPlayType advertises HLS",
    context: {
      streamType: "hls",
      recommendedPlayer: "avplayer",
      preferNativeHls: false,
      capabilities: { nativeHls: true, hlsJs: true },
    },
    expected: "hls-js",
  },
  {
    name: "falls back to native HLS when MSE is unavailable",
    context: {
      streamType: "m3u8",
      preferNativeHls: false,
      capabilities: { nativeHls: true },
    },
    expected: "native",
  },
  {
    name: "uses mpegts for live transport streams",
    context: { streamType: "xtream", capabilities: { mpegts: true } },
    expected: "mpegts",
  },
  {
    name: "tries mpegts before a remembered AVPlayer on Firefox live TS",
    context: {
      streamType: "ts",
      recommendedPlayer: "avplayer",
      shouldPreferAVPlayerForLiveTs: true,
      capabilities: { mpegts: true },
    },
    expected: "mpegts",
  },
  {
    name: "tries mpegts before a remembered AVPlayer on Firefox Xtream",
    context: {
      streamType: "xtream",
      recommendedPlayer: "avplayer",
      shouldPreferAVPlayerForLiveTs: true,
      capabilities: { mpegts: true },
    },
    expected: "mpegts",
  },
  {
    name: "tries mpegts before remembered AVPlayer on non-Firefox raw TS too",
    context: {
      streamType: "ts",
      recommendedPlayer: "avplayer",
      capabilities: { mpegts: true },
    },
    expected: "mpegts",
  },
  {
    name: "uses AVPlayer for Firefox live TS when mpegts is unavailable",
    context: {
      streamType: "ts",
      shouldPreferAVPlayerForLiveTs: true,
      capabilities: { hlsJs: true, mpegts: false },
    },
    expected: "avplayer",
  },
  {
    name: "never routes raw Xtream TS to hls.js",
    context: {
      streamType: "xtream",
      capabilities: { hlsJs: true, mpegts: false },
    },
    expected: "native",
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
