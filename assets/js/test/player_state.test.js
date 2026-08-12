import assert from "node:assert/strict";
import test from "node:test";

import { createInitialPlayerState } from "../player/player_state.js";

const createElement = (dataset = {}) => ({ dataset });

test("builds one explicit player state from the hook dataset", () => {
  const playbackMetrics = { session: 7 };
  const state = createInitialPlayerState(
    createElement({
      contentId: "42",
      contentType: "vod",
      expectedDuration: "7200",
      featureAvbridge: "true",
      imdbId: "tt123",
      mediaTitle: "Filme",
      nextEpisode: '{"id":9}',
      playerLifecycleLogs: "true",
      sourceType: "gindex",
      streamUrl: "/stream/42",
      subtitleOffsetMs: "250",
      subtitlesEnabled: "false",
    }),
    {
      documentRef: { title: "Fallback title" },
      dependencies: {
        createPlaybackMetrics: () => playbackMetrics,
        isIosPwaMode: () => true,
        now: () => 1234,
        parseNextEpisode: () => ({ id: 9 }),
        readEngineFlag: (_el, engine) => engine === "avbridge",
        selectStreamingMode: (contentType, quality) => `${contentType}:${quality}`,
      },
    },
  );

  assert.equal(state.contentId, "42");
  assert.equal(state.contentType, "vod");
  assert.equal(state.streamingMode, "vod:good");
  assert.equal(state.expectedDuration, 7200);
  assert.equal(state.subtitleOffsetMs, 250);
  assert.equal(state.subtitlesEnabled, false);
  assert.equal(state.featureFlagAvbridge, true);
  assert.equal(state.featureFlagH265web, false);
  assert.equal(state.iosPwaMode, true);
  assert.equal(state.startTime, 1234);
  assert.strictEqual(state.playbackMetrics, playbackMetrics);
  assert.deepEqual(state.nextEpisode, { id: 9 });
  assert.equal(state.nextEpisodeParseFailed, false);
  assert.equal(state._destroyed, false);
});

test("uses live defaults, rejects malformed numeric state, and reports invalid next episode data", () => {
  let selectedContentType;
  const state = createInitialPlayerState(
    createElement({
      nextEpisode: "not-json",
      subtitleOffsetMs: "invalid",
    }),
    {
      documentRef: { title: "Document title" },
      dependencies: {
        createPlaybackMetrics: () => ({}),
        isIosPwaMode: () => false,
        now: () => 0,
        parseNextEpisode: () => null,
        readEngineFlag: () => false,
        selectStreamingMode: (contentType) => {
          selectedContentType = contentType;
          return "automatic-live";
        },
      },
    },
  );

  assert.equal(state.contentType, "live");
  assert.equal(selectedContentType, "live");
  assert.equal(state.streamingMode, "automatic-live");
  assert.equal(state.subtitleOffsetMs, 0);
  assert.equal(state.mediaTitle, "Document title");
  assert.equal(state.nextEpisodeParseFailed, true);
});

test("does not share mutable defaults between player instances", () => {
  const dependencies = {
    createPlaybackMetrics: () => ({}),
    isIosPwaMode: () => false,
    now: () => 0,
    parseNextEpisode: () => null,
    readEngineFlag: () => false,
    selectStreamingMode: () => "live",
  };
  const first = createInitialPlayerState(createElement(), { dependencies });
  const second = createInitialPlayerState(createElement(), { dependencies });

  first.audioTracks.push({ id: 1 });
  first.fallbackCooldowns.push(60_000);

  assert.deepEqual(second.audioTracks, []);
  assert.deepEqual(second.fallbackCooldowns, [2_000, 5_000, 10_000, 20_000, 30_000]);
});
