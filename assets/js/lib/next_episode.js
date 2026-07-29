const ALLOWED_TYPES = new Set(["episode", "movie", "live"]);

export function parseNextEpisode(serialized) {
  if (typeof serialized !== "string" || serialized.trim() === "") return null;

  try {
    const episode = JSON.parse(serialized);
    return episode && typeof episode === "object" && !Array.isArray(episode) ? episode : null;
  } catch {
    return null;
  }
}

export function shouldTriggerNextEpisode(currentTime, duration) {
  if (
    !Number.isFinite(currentTime) ||
    !Number.isFinite(duration) ||
    currentTime < 0 ||
    duration <= 0
  ) {
    return false;
  }

  const timeRemaining = duration - currentTime;
  const percentComplete = (currentTime / duration) * 100;
  return timeRemaining <= 30 || percentComplete >= 90;
}

export function nextEpisodePath(nextEpisode) {
  if (!nextEpisode) return null;

  const type = ALLOWED_TYPES.has(nextEpisode.type) ? nextEpisode.type : "episode";
  const rawId = String(nextEpisode.id ?? "").trim();
  if (!/^[1-9]\d*$/.test(rawId)) return null;

  return `/watch/${type}/${rawId}`;
}

export function nextEpisodeCountdownWidth(secondsRemaining, totalSeconds = 10) {
  if (!Number.isFinite(secondsRemaining) || !Number.isFinite(totalSeconds) || totalSeconds <= 0) {
    return 0;
  }

  return (Math.min(Math.max(secondsRemaining, 0), totalSeconds) / totalSeconds) * 100;
}
