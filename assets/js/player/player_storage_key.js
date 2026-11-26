const ENTITY_TYPES = new Set(["movie", "episode", "live_channel", "torrent"]);

export function playerStorageKey(scope, entityType, contentId) {
  const entity =
    { gindex: "movie", gindex_episode: "episode", live: "live_channel" }[entityType] || entityType;
  if (
    !/^[A-Za-z0-9_-]{43}$/.test(scope || "") ||
    !ENTITY_TYPES.has(entity) ||
    !/^[1-9]\d{0,18}$/.test(String(contentId))
  )
    return null;
  return `v2:${scope}:${entity}:${contentId}`;
}

export function validPlayerStorageKey(key) {
  return (
    typeof key === "string" &&
    /^v2:[A-Za-z0-9_-]{43}:(movie|episode|live_channel|torrent):[1-9]\d{0,18}$/.test(key)
  );
}
