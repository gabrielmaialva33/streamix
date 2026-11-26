import assert from "node:assert/strict";
import test from "node:test";
import {
  getPlaybackPosition,
  getPreferences,
  saveAudioTrack,
  savePlaybackPosition,
} from "../player/player_preferences.js";
import { playerStorageFixture } from "../smoke/player_storage_fixture.js";

function storage(t, initial = {}) {
  const values = new Map(Object.entries(initial));
  const previous = globalThis.localStorage;
  globalThis.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
  t.after(() => {
    globalThis.localStorage = previous;
  });
  return values;
}

test("ambiguous legacy positions and tracks are discarded but device volume survives", (t) => {
  const values = storage(t, {
    streamix_playback_positions: JSON.stringify({ 42: { time: 120, duration: 1000 } }),
    streamix_player_prefs: JSON.stringify({ global: { volume: 0.3 }, 42: { audioTrack: 2 } }),
  });
  assert.equal(getPlaybackPosition("42"), null);
  assert.equal(getPreferences("42").audioTrack, null);
  assert.equal(getPreferences().volume, 0.3);
  assert.equal(values.has("streamix_playback_positions"), false);
  assert.equal(values.has("streamix_player_prefs"), false);
});

test("positions and tracks remain distinct for two entities and two accounts", (t) => {
  storage(t);
  const movie = `v2:${"a".repeat(43)}:movie:42`;
  const episode = `v2:${"a".repeat(43)}:episode:42`;
  const otherAccount = `v2:${"b".repeat(43)}:movie:42`;
  savePlaybackPosition(movie, 120, 1000);
  savePlaybackPosition(episode, 250, 1000);
  saveAudioTrack(2, movie);
  saveAudioTrack(3, episode);
  assert.deepEqual(getPlaybackPosition(movie), { time: 120, duration: 1000 });
  assert.deepEqual(getPlaybackPosition(episode), { time: 250, duration: 1000 });
  assert.equal(getPlaybackPosition(otherAccount), null);
  assert.equal(getPreferences(movie).audioTrack, 2);
  assert.equal(getPreferences(episode).audioTrack, 3);
  assert.equal(getPreferences(otherAccount).audioTrack, null);
});

test("the browser smoke seeds the same scoped keys read by the real player", (t) => {
  const dataset = { storageScope: "a".repeat(43), entityType: "movie", contentId: "42" };
  const entries = playerStorageFixture(dataset, { resumeTime: 123, volume: 0.72 });
  storage(t, Object.fromEntries(entries));
  assert.equal(getPreferences().volume, 0.72);
  assert.equal(getPreferences().muted, true);
  assert.equal(getPlaybackPosition(`v2:${dataset.storageScope}:movie:42`).time, 123);
  assert.equal(getPlaybackPosition(`v2:${dataset.storageScope}:episode:42`), null);
});
