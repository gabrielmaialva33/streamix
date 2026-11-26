import { playerStorageKey } from "../player/player_storage_key.js";

export function playerStorageFixture(dataset, { resumeTime, volume }) {
  const key = playerStorageKey(dataset.storageScope, dataset.entityType, dataset.contentId);
  if (!key) throw new Error("Player smoke requires authenticated storage datasets");
  return [
    [
      "streamix_playback_positions_v2",
      JSON.stringify({ [key]: { time: resumeTime, duration: 7200, timestamp: Date.now() } }),
    ],
    ["streamix_player_prefs_v2", JSON.stringify({ global: { muted: true, volume } })],
  ];
}
