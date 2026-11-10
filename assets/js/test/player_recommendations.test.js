import assert from "node:assert/strict";
import test from "node:test";
import * as preferences from "../player/player_preferences.js";

test("old provider memory learned from playing events does not count as frame-confirmed evidence", (t) => {
  storage(t);
  globalThis.localStorage.setItem(
    "streamix_device_compat",
    JSON.stringify({
      schema: 4,
      codecs: {},
      players: {
        "provider:3:mp4": {
          recommendedPlayer: "avplayer",
          successCount: 2,
          lastSuccess: Date.now(),
        },
      },
    }),
  );
  assert.equal(preferences.getRecommendedPlayer("provider:3:mp4"), null);
});

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

test("recommendations expire after three days and a different engine starts fresh evidence", (t) => {
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
  now += 3 * 24 * 60 * 60 * 1000 + 1;
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

test("daily memory-selected successes cannot keep AVPlayer recommended beyond three days", (t) => {
  storage(t);
  let now = 1000000;
  t.mock.method(Date, "now", () => now);
  const key = "provider:3:mp4";
  preferences.recordPlayerSuccess(key, "avplayer");
  preferences.recordPlayerSuccess(key, "avplayer");
  assert.equal(preferences.getRecommendedPlayer(key), "avplayer");
  for (let day = 1; day <= 30; day++) {
    now += 86400000;
    preferences.recordPlayerSuccess(key, "avplayer", {
      selectionReason: "provider_memory",
      ttffMs: 1000,
    });
    assert.equal(preferences.getRecommendedPlayer(key), day < 3 ? "avplayer" : null);
  }
});

test("one stable native success removes AV recommendation, while slow AV success adds no evidence", (t) => {
  storage(t);
  const key = "provider:3:mp4";
  preferences.recordPlayerSuccess(key, "avplayer", { ttffMs: 15001 });
  preferences.recordPlayerSuccess(key, "avplayer", { ttffMs: 15001 });
  assert.equal(preferences.getRecommendedPlayer(key), null);
  preferences.recordPlayerSuccess(key, "avplayer", { ttffMs: 15000 });
  preferences.recordPlayerSuccess(key, "avplayer", { ttffMs: 15000 });
  assert.equal(preferences.getRecommendedPlayer(key), "avplayer");
  preferences.recordPlayerSuccess(key, "native");
  assert.equal(preferences.getRecommendedPlayer(key), null);
  const entry = JSON.parse(localStorage.getItem("streamix_device_compat")).players[key];
  assert.equal(entry.recommendedPlayer, "native");
});
