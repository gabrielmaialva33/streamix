/**
 * Stable per-tab client identity.
 *
 * The id is minted once per browsing context and kept in sessionStorage, so
 * it survives LiveView reconnects, reloads and same-tab navigation while a
 * second tab or device still gets its own id. The server uses it to let a
 * reconnecting client supersede its own playback session instead of counting
 * it as a second screen.
 */

export const CLIENT_ID_STORAGE_KEY = "streamix:client-id";
const CLIENT_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;

function randomId(randomUUID) {
  if (typeof randomUUID === "function") {
    try {
      const value = randomUUID();
      if (typeof value === "string" && value.length > 0) return value.replaceAll("-", "");
    } catch {
      // fall through to the timestamp/random fallback
    }
  }
  const time = Date.now().toString(36);
  const rand = Math.random().toString(36).slice(2, 14);
  return `${time}${rand}`;
}

export function isValidClientId(value) {
  return typeof value === "string" && CLIENT_ID_PATTERN.test(value);
}

/**
 * Returns the per-tab client id, minting and persisting one when absent.
 * Storage access is wrapped: a private window or a blocked storage still
 * yields a usable id for the current page load.
 */
export function getClientId({
  storage = globalThis.sessionStorage,
  randomUUID = globalThis.crypto?.randomUUID?.bind(globalThis.crypto),
} = {}) {
  let existing = null;
  try {
    existing = storage?.getItem(CLIENT_ID_STORAGE_KEY) ?? null;
  } catch {
    existing = null;
  }
  if (isValidClientId(existing)) return existing;

  const minted = randomId(randomUUID);
  try {
    storage?.setItem(CLIENT_ID_STORAGE_KEY, minted);
  } catch {
    // storage unavailable: the id lives for this page load only
  }
  return minted;
}
