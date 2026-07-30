import assert from "node:assert/strict";
import test from "node:test";
import { buildNativePlaybackSnapshot } from "../player/native_playback_snapshot.js";

test("builds a bounded native playback diagnostic snapshot", () => {
  const video = {
    currentTime: 12.34567,
    duration: Number.POSITIVE_INFINITY,
    readyState: 3,
    networkState: 2,
    paused: false,
    seeking: true,
    autoplay: true,
    preload: "",
    currentSrc: "https://example.test/video.mkv",
    buffered: {
      length: 2,
      start: (index) => [0, 10.5][index],
      end: (index) => [5.123, 20][index],
    },
    getAttribute: () => "metadata",
  };

  assert.deepEqual(buildNativePlaybackSnapshot(video), {
    current_time: 12.346,
    duration: 0,
    ready_state: 3,
    network_state: 2,
    paused: false,
    seeking: true,
    autoplay: true,
    preload: "metadata",
    buffered_range_count: 2,
    buffered_ranges: "0.00-5.12,10.50-20.00",
    has_current_src: true,
  });
});

test("returns an empty snapshot when no media element exists", () => {
  assert.deepEqual(buildNativePlaybackSnapshot(null), {});
});
