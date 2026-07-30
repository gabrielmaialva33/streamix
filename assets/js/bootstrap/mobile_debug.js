const ENABLE_KEY = "streamix:eruda";

export function installMobileDebug() {
  // Opt-in on-device console for iOS. The dependency stays outside the
  // production bundle and is downloaded only after an explicit `#debug`.
  const wantsDebug = location.hash === "#debug" || sessionStorage.getItem(ENABLE_KEY) === "1";
  if (!wantsDebug) return;

  sessionStorage.setItem(ENABLE_KEY, "1");
  const script = document.createElement("script");
  script.src = "https://cdn.jsdelivr.net/npm/eruda";
  script.onload = () => window.eruda?.init();
  document.body.appendChild(script);
}
