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
// Why playback failed, as far as the engine can tell. Bounded so a browser
// cannot invent new labels.
export const ERROR_CODES = new Set([
  "media_aborted",
  "media_network",
  "media_decode",
  "media_unsupported",
  "media_unknown",
  "play_rejected",
]);
export const errorCode = (code) => (ERROR_CODES.has(code) ? code : undefined);
// MediaError codes 1-4, per the HTML spec.
export const mediaErrorCode = (error) =>
  ({ 1: "media_aborted", 2: "media_network", 3: "media_decode", 4: "media_unsupported" })[
    error?.code
  ] ?? "media_unknown";
export const endReason = (reason) => (END_REASONS.has(reason) ? reason : "unknown");
export const engineReason = (reason) => (ENGINE_REASONS.has(reason) ? reason : "unknown");
export const clientRevision = (revision) =>
  typeof revision === "string" && /^[0-9a-f]{7,40}$/i.test(revision)
    ? revision.toLowerCase()
    : undefined;
