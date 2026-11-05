// Sends one playback-quality sample with navigator.sendBeacon(). Used when
// the page is going away: a LiveView push at that moment is lost with the
// socket, while a beacon outlives the page. The session cookie authenticates
// it and the CSRF token travels in the body, since a beacon cannot set
// headers. The server stores a sample once even if the socket delivered it.
export const QOE_BEACON_PATH = "/api/qoe/beacon";

export function sendQoeBeacon(
  sample,
  { navigatorRef = globalThis.navigator, documentRef = globalThis.document } = {},
) {
  if (!sample || typeof navigatorRef?.sendBeacon !== "function") return false;

  const csrfToken = documentRef?.querySelector?.('meta[name="csrf-token"]')?.content;
  if (!csrfToken) return false;

  try {
    const body = new Blob([JSON.stringify({ ...sample, _csrf_token: csrfToken })], {
      type: "application/json",
    });
    return navigatorRef.sendBeacon(QOE_BEACON_PATH, body) === true;
  } catch {
    return false;
  }
}
