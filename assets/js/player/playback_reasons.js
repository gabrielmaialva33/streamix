export const END_REASONS = new Set([
  "completed",
  "navigation",
  "first_frame_then_user_left",
  "user_retry",
  "startup_deadline",
  "recovery_deadline",
  "retry_budget",
  "fatal_media_error",
  "network_error",
  "unknown",
]);
export const ENGINE_REASONS = new Set([
  "capability",
  "provider_memory",
  "format_memory",
  "fallback_audio",
  "fallback_codec",
  "failover",
  "user_choice",
  "unknown",
]);
export const endReason = (reason) => (END_REASONS.has(reason) ? reason : "unknown");
export const engineReason = (reason) => (ENGINE_REASONS.has(reason) ? reason : "unknown");
export const clientRevision = (revision) =>
  typeof revision === "string" && /^[0-9a-f]{7,40}$/i.test(revision)
    ? revision.toLowerCase()
    : undefined;
