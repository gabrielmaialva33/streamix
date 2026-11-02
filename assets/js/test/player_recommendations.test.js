import assert from "node:assert/strict";
import test from "node:test";
import * as preferences from "../player/player_preferences.js";

function storage(t) {
  const values = new Map();
  const previous = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  globalThis.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "localStorage", previous);
    else delete globalThis.localStorage;
  });
}

test("AVPlayer experience cannot leak to another provider, container or unidentified source", (t) => {
  storage(t);
  assert.equal(typeof preferences.playerRecommendationKey, "function");
  const key = preferences.playerRecommendationKey({ providerId: "3", streamType: "mp4" });
  preferences.recordPlayerSuccess(key, "avplayer");
  preferences.recordPlayerSuccess(key, "avplayer");
  assert.equal(preferences.getRecommendedPlayer(key), "avplayer");
  assert.equal(preferences.getRecommendedPlayer("provider:4:mp4"), null);
  assert.equal(preferences.getRecommendedPlayer("provider:3:mkv"), null);
  assert.equal(preferences.playerRecommendationKey({ streamType: "mp4" }), null);
  preferences.recordPlayerSuccess("mp4", "avplayer");
  preferences.recordPlayerSuccess("mp4", "avplayer");
  assert.equal(preferences.getRecommendedPlayer("mp4"), null);
});

test("recommendations expire after seven days and a different engine starts fresh evidence", (t) => {
  storage(t);
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  t.after(() => {
    Date.now = originalNow;
  });
  const key = "provider:3:mp4";
  preferences.recordPlayerSuccess(key, "native");
  preferences.recordPlayerSuccess(key, "native");
  preferences.recordPlayerSuccess(key, "avplayer");
  assert.equal(preferences.getRecommendedPlayer(key), null);
  preferences.recordPlayerSuccess(key, "avplayer");
  assert.equal(preferences.getRecommendedPlayer(key), "avplayer");
  now += 7 * 24 * 60 * 60 * 1000 + 1;
  assert.equal(preferences.getRecommendedPlayer(key), null);
  preferences.recordPlayerSuccess(key, "avplayer");
  assert.equal(
    preferences.getRecommendedPlayer(key),
    null,
    "expired evidence cannot revive on one play",
  );
  preferences.recordPlayerSuccess(key, "avplayer");
  preferences.forgetRecommendedPlayer(key);
  assert.equal(preferences.getRecommendedPlayer(key), null);
});
