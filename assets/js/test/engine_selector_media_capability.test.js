import assert from "node:assert/strict";
import test from "node:test";

import { ENGINE_SELECTION } from "../player/engine_contract.js";
import { selectEngine } from "../player/engine_selector.js";

function context(overrides = {}) {
  const capabilities = {
    nativeHls: false,
    hlsJs: true,
    mpegts: true,
    ...(overrides.capabilities ?? {}),
  };

  return {
    streamType: "mp4",
    sourceType: "provider",
    capabilities,
    canTryAVPlayer: true,
    canTryAvbridge: false,
    canTryH265web: false,
    isUhdHevc: false,
    isVodContainer: true,
    recommendedPlayer: null,
    preferAVPlayer: false,
    shouldPreferAVPlayerForLiveTs: false,
    preferNativeHls: false,
    mediaCapability: null,
    ...overrides,
  };
}

test("Media Capabilities can prefer native HLS on an efficient device", () => {
  const selected = selectEngine(
    context({
      streamType: "hls",
      capabilities: { nativeHls: true },
      mediaCapability: {
        preferNative: true,
        avoidNative: false,
      },
    }),
  );

  assert.equal(selected, ENGINE_SELECTION.NATIVE);
});

test("a non-smooth native profile keeps HLS on hls.js", () => {
  const selected = selectEngine(
    context({
      streamType: "hls",
      capabilities: { nativeHls: true, hlsJs: true },
      preferNativeHls: true,
      mediaCapability: {
        preferNative: false,
        avoidNative: true,
      },
    }),
  );

  assert.equal(selected, ENGINE_SELECTION.HLS_JS);
});

test("a risky native MP4 profile selects AVPlayer when available", () => {
  const selected = selectEngine(
    context({
      streamType: "mp4",
      mediaCapability: {
        avoidNative: true,
      },
    }),
  );

  assert.equal(selected, ENGINE_SELECTION.AVPLAYER);
});

test("GIndex avoids native playback when capability probing rejects it", () => {
  const selected = selectEngine(
    context({
      streamType: "mkv",
      sourceType: "gindex",
      mediaCapability: {
        avoidNative: true,
      },
    }),
  );

  assert.equal(selected, ENGINE_SELECTION.AVPLAYER);
});
