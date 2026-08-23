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

test("round-trips one canonical fresh state for the same content", () => {
  const storage = memoryStorage();
  const state = { contentId: "42", time: 90, duration: 120 };

  assert.equal(writeIosPlayerState(state, { storage, now: 1_000 }), true);
  assert.deepEqual(readIosPlayerState("42", { storage, now: 2_000 }), {
    contentId: "42",
    path: "",
    time: 90,
    duration: 120,
    paused: false,
    userPaused: false,
    wasPlaying: true,
    muted: false,
    volume: 1,
    playbackRate: 1,
    reason: "snapshot",
    savedAt: 1_000,
  });
});

test("rejects stale, mismatched, future-dated, and malformed persisted state", () => {
  const storage = memoryStorage();
  writeIosPlayerState({ contentId: "42", time: 10, duration: 120 }, { storage, now: 1_000 });

  assert.equal(readIosPlayerState("other", { storage, now: 2_000 }), null);
  assert.equal(readIosPlayerState("42", { storage, now: 20_000, maxAge: 5_000 }), null);

  storage.setItem(
    IOS_PLAYER_STATE_KEY,
    JSON.stringify({ contentId: "42", time: 10, duration: 120, savedAt: 500_000 }),
  );
  assert.equal(readIosPlayerState("42", { storage, now: 2_000 }), null);

  storage.setItem(IOS_PLAYER_STATE_KEY, "{broken");
  assert.equal(readIosPlayerState("42", { storage, now: 2_000 }), null);
});

test("builds one bounded canonical snapshot", () => {
  assert.deepEqual(
    buildIosPlayerState(
      {
        contentId: "42",
        path: "/watch/episode/42",
        currentTime: 180,
        duration: 120,
        paused: false,
        muted: true,
        volume: 8,
        playbackRate: 12,
      },
      { reason: "hidden", userPaused: false, wasPlaying: true },
    ),
    {
      contentId: "42",
      path: "/watch/episode/42",
      time: 120,
      duration: 120,
      paused: false,
      userPaused: false,
      wasPlaying: true,
      muted: true,
      volume: 1,
      playbackRate: 2,
      reason: "hidden",
    },
  );

  assert.deepEqual(
    buildIosPlayerState({
      contentId: 42,
      currentTime: -10,
      duration: 120,
      paused: true,
      volume: -4,
      playbackRate: 0,
    }),
    {
      contentId: "42",
      path: "",
      time: 0,
      duration: 120,
      paused: true,
      userPaused: true,
      wasPlaying: false,
      muted: false,
      volume: 0,
      playbackRate: 0.25,
      reason: "snapshot",
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

test("sanitizes tampered local state before it reaches the player", () => {
  const storage = memoryStorage();
  storage.setItem(
    IOS_PLAYER_STATE_KEY,
    JSON.stringify({
      contentId: "42",
      path: 123,
      time: -500,
      duration: 120,
      paused: "false",
      userPaused: "false",
      wasPlaying: "true",
      muted: "true",
      volume: -10,
      playbackRate: 99,
      reason: 123,
      savedAt: 1_000,
    }),
  );

  assert.deepEqual(readIosPlayerState("42", { storage, now: 2_000 }), {
    contentId: "42",
    path: "",
    time: 0,
    duration: 120,
    paused: false,
    userPaused: false,
    wasPlaying: true,
    muted: false,
    volume: 0,
    playbackRate: 2,
    reason: "snapshot",
    savedAt: 1_000,
  });
});

test("refuses to write malformed snapshots", () => {
  const storage = memoryStorage();

  assert.equal(
    writeIosPlayerState({ contentId: "42", time: 10, duration: Number.NaN }, { storage }),
    false,
  );
  assert.equal(storage.getItem(IOS_PLAYER_STATE_KEY), null);
});
