import assert from "node:assert/strict";
import test from "node:test";

import {
  buildIosPlayerState,
  IOS_PLAYER_STATE_KEY,
  readIosPlayerState,
  writeIosPlayerState,
} from "../player/ios_playback_state.js";

function memoryStorage() {
  const values = new Map();

  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
}

test("round-trips a fresh state for the same content", () => {
  const storage = memoryStorage();
  const state = { contentId: "42", time: 90, duration: 120 };

  assert.equal(writeIosPlayerState(state, { storage, now: 1_000 }), true);
  assert.deepEqual(readIosPlayerState("42", { storage, now: 2_000 }), {
    ...state,
    savedAt: 1_000,
  });
});

test("rejects stale, mismatched, and malformed persisted state", () => {
  const storage = memoryStorage();
  writeIosPlayerState({ contentId: "42" }, { storage, now: 1_000 });

  assert.equal(readIosPlayerState("other", { storage, now: 2_000 }), null);
  assert.equal(readIosPlayerState("42", { storage, now: 20_000, maxAge: 5_000 }), null);

  storage.setItem(IOS_PLAYER_STATE_KEY, "{broken");
  assert.equal(readIosPlayerState("42", { storage, now: 2_000 }), null);
});

test("builds one canonical snapshot and rejects invalid timelines", () => {
  assert.deepEqual(
    buildIosPlayerState(
      {
        contentId: "42",
        path: "/watch/episode/42",
        currentTime: 90,
        duration: 120,
        paused: false,
        muted: true,
        volume: 0.5,
        playbackRate: 1.25,
      },
      { reason: "hidden", userPaused: false, wasPlaying: true },
    ),
    {
      contentId: "42",
      path: "/watch/episode/42",
      time: 90,
      duration: 120,
      paused: false,
      userPaused: false,
      wasPlaying: true,
      muted: true,
      volume: 0.5,
      playbackRate: 1.25,
      reason: "hidden",
    },
  );

  assert.equal(
    buildIosPlayerState({
      contentId: "42",
      currentTime: 10,
      duration: Number.NaN,
      paused: true,
    }),
    null,
  );
});
