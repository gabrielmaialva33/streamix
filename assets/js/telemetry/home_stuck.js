export function installHomeStuckDiagnostics({ liveSocket, isStandalonePwa, isIosWebKit }) {
  // A delayed beacon distinguishes a stuck LiveView transport from stale PWA
  // HTML without blocking or changing the user's navigation.
  window.setTimeout(() => {
    const skeleton = document.querySelector('[data-loading-home="true"]');
    if (!skeleton) return;

    try {
      navigator.sendBeacon(
        "/api/internal/home-stuck",
        new Blob(
          [
            JSON.stringify({
              ua: navigator.userAgent,
              transport: liveSocket?.transport?.name || null,
              connected: !!liveSocket?.isConnected?.(),
              standalone: isStandalonePwa(),
              iosWebkit: isIosWebKit(),
              at: new Date().toISOString(),
            }),
          ],
          { type: "application/json" },
        ),
      );
    } catch {}
  }, 8000);
}
