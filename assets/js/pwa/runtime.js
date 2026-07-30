import {
  clearStreamixCaches,
  fetchExpectedCacheName,
  repairPwaApp,
  streamixCacheNames,
} from "./cache_management";
import { promptForPwaInstall, pwaInstallMode } from "./pwa_install";

const LAST_ROUTE_KEY = "streamix:pwa-last-route";
const LAST_ROUTE_MAX_AGE = 7 * 24 * 60 * 60 * 1000;
const PWA_BOOTED_KEY = "streamix:pwa-booted";
const PWA_INSTALL_STATE_EVENT = "streamix:pwa-install-state";

const safeStorage = {
  get(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch {}
  },
};

const currentRoute = () =>
  `${window.location.pathname}${window.location.search}${window.location.hash}`;

const isRestorableRoute = (route) => {
  if (!route || route === "/" || route.startsWith("//")) return false;
  const path = route.split(/[?#]/)[0];
  if (
    path.startsWith("/admin") ||
    path.startsWith("/api") ||
    path.startsWith("/assets") ||
    path.startsWith("/live") ||
    path.startsWith("/login") ||
    path.startsWith("/logout") ||
    path.startsWith("/register") ||
    path.startsWith("/offline")
  ) {
    return false;
  }

  return [
    /^\/watch\//,
    /^\/browse/,
    /^\/providers\//,
    /^\/favorites$/,
    /^\/history$/,
    /^\/settings$/,
    /^\/search/,
    /^\/gindex/,
    /^\/party/,
  ].some((pattern) => pattern.test(path));
};

const rememberCurrentRoute = () => {
  const route = currentRoute();
  if (!isRestorableRoute(route)) return;
  safeStorage.set(LAST_ROUTE_KEY, JSON.stringify({ route, savedAt: Date.now() }));
};

const restoreLastPwaRoute = (isStandalonePwa) => {
  if (!isStandalonePwa() || currentRoute() !== "/") return;

  // Only restore on a PWA cold-start. A normal Home navigation may cross
  // live_sessions and reload the document, but must not bounce back to browse.
  try {
    if (sessionStorage.getItem(PWA_BOOTED_KEY) === "1") return;
    sessionStorage.setItem(PWA_BOOTED_KEY, "1");
  } catch {}

  try {
    const saved = JSON.parse(safeStorage.get(LAST_ROUTE_KEY) || "null");
    if (!saved?.route || Date.now() - saved.savedAt > LAST_ROUTE_MAX_AGE) return;
    if (!isRestorableRoute(saved.route)) return;
    window.location.replace(saved.route);
  } catch {}
};

let connectionToastTimer = null;

const showConnectionToast = (state) => {
  document.getElementById("connection-toast")?.remove();
  window.clearTimeout(connectionToastTimer);

  const toast = document.createElement("div");
  toast.id = "connection-toast";
  toast.className =
    "fixed inset-x-4 bottom-4 z-[9999] rounded-lg border border-border bg-surface/95 px-4 py-3 text-sm text-text-primary shadow-2xl backdrop-blur safe-area-bottom";
  toast.textContent =
    state === "offline"
      ? "Sem conexão. Algumas ações podem esperar a rede voltar."
      : "Conexão restaurada.";
  document.body.appendChild(toast);

  if (state !== "offline") {
    connectionToastTimer = window.setTimeout(() => toast.remove(), 2500);
  }
};

export function installPwaRuntime({ getLiveSocket }) {
  const displayModeQuery = window.matchMedia?.("(display-mode: standalone)");
  const isIosWebKit = () =>
    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const isStandalonePwa = () =>
    displayModeQuery?.matches === true || window.navigator.standalone === true;

  const applyPwaModeClasses = () => {
    const standalone = isStandalonePwa();
    const ios = isIosWebKit();
    document.documentElement.classList.toggle("pwa-standalone", standalone);
    document.documentElement.classList.toggle("ios-webkit", ios);
    document.documentElement.classList.toggle("ios-pwa", ios && standalone);
    document.documentElement.dataset.displayMode = standalone ? "standalone" : "browser";
  };

  applyPwaModeClasses();
  if (displayModeQuery?.addEventListener) {
    displayModeQuery.addEventListener("change", applyPwaModeClasses);
  } else if (displayModeQuery?.addListener) {
    displayModeQuery.addListener(applyPwaModeClasses);
  }

  let deferredPwaInstallPrompt = null;
  const installState = () =>
    pwaInstallMode({
      standalone: isStandalonePwa(),
      iosWebKit: isIosWebKit(),
      hasNativePrompt: deferredPwaInstallPrompt !== null,
    });
  const publishInstallState = () => {
    window.dispatchEvent(
      new CustomEvent(PWA_INSTALL_STATE_EVENT, {
        detail: { state: installState() },
      }),
    );
  };
  const installApp = async () => {
    const state = installState();
    if (state === "ios") return { outcome: "instructions", platform: "ios" };
    if (state !== "native") return { outcome: state, platform: null };

    const promptEvent = deferredPwaInstallPrompt;
    deferredPwaInstallPrompt = null;
    try {
      return await promptForPwaInstall(promptEvent);
    } finally {
      publishInstallState();
    }
  };

  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    deferredPwaInstallPrompt = event;
    publishInstallState();
  });
  window.addEventListener("appinstalled", () => {
    deferredPwaInstallPrompt = null;
    publishInstallState();
  });

  window.StreamixPwa = {
    clearCaches: clearStreamixCaches,
    expectedCacheName: fetchExpectedCacheName,
    installApp,
    installState,
    repairApp: repairPwaApp,
    streamixCacheNames,
  };

  restoreLastPwaRoute(isStandalonePwa);
  window.addEventListener("pageshow", rememberCurrentRoute);
  window.addEventListener("popstate", rememberCurrentRoute);
  window.addEventListener("phx:page-loading-stop", () =>
    window.setTimeout(rememberCurrentRoute, 0),
  );
  window.addEventListener("offline", () => showConnectionToast("offline"));
  window.addEventListener("online", () => {
    showConnectionToast("online");
    const liveSocket = getLiveSocket();
    if (liveSocket && !liveSocket.isConnected()) liveSocket.socket.connect();
  });

  return { isIosWebKit, isStandalonePwa };
}
