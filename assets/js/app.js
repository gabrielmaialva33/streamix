// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Alpine.js for reactive UI components
import Alpine from "alpinejs";
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/streamix";
import topbar from "../vendor/topbar";
import customHooks from "./hooks";
import { getEnvInfo } from "./lib/logger";

window.Alpine = Alpine;
Alpine.start();

// Global poster / cover fallback. Some catalog images live on aging
// CDN77 mirrors (e.g. `gstaticontent.com/images/<md5>.jpg`) and
// occasionally 404 because the upstream pulled the asset. Without
// any listener the browser leaves a broken-image icon and the
// console fills with passthrough 404s from `img.mahina.cloud/proxy`.
// Swap to a lightweight inline SVG placeholder on the first error
// per element, and tag the element so a 404 on the placeholder
// itself never causes an infinite swap loop.
//
// `error` does not bubble, so the listener has to register in the
// capture phase to see it from `document`.
const POSTER_FALLBACK_SRC = "/images/poster-fallback.svg";
document.addEventListener(
  "error",
  (event) => {
    const target = event.target;
    if (!(target instanceof HTMLImageElement)) return;
    if (target.dataset.fallbackApplied === "1") return;
    target.dataset.fallbackApplied = "1";
    target.removeAttribute("srcset");
    target.src = POSTER_FALLBACK_SRC;
  },
  true,
);

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const displayModeQuery = window.matchMedia?.("(display-mode: standalone)");
const INSTALL_HINT_DISMISSED_KEY = "streamix:pwa-install-hint-dismissed";
const LAST_ROUTE_KEY = "streamix:pwa-last-route";
const LAST_ROUTE_MAX_AGE = 7 * 24 * 60 * 60 * 1000;
const STREAMIX_CACHE_PREFIX = "streamix-";

const isIosWebKit = () =>
  /iPad|iPhone|iPod/.test(navigator.userAgent) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

const isStandalonePwa = () =>
  displayModeQuery?.matches === true || window.navigator.standalone === true;

const isSafariBrowser = () => {
  const ua = navigator.userAgent || "";
  return /Safari/i.test(ua) && !/(CriOS|FxiOS|EdgiOS|OPiOS|Chrome|Android)/i.test(ua);
};

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

const restoreLastPwaRoute = () => {
  if (!isStandalonePwa() || currentRoute() !== "/") return;

  try {
    const saved = JSON.parse(safeStorage.get(LAST_ROUTE_KEY) || "null");
    if (!saved?.route || Date.now() - saved.savedAt > LAST_ROUTE_MAX_AGE) return;
    if (!isRestorableRoute(saved.route)) return;
    window.location.replace(saved.route);
  } catch {}
};

const createIconButton = (label, text) => {
  const button = document.createElement("button");
  button.type = "button";
  button.className =
    "shrink-0 rounded-md px-2 py-1 text-sm text-text-secondary hover:text-text-primary";
  button.setAttribute("aria-label", label);
  button.textContent = text;
  return button;
};

const showIosInstallHint = () => {
  if (!isIosWebKit() || !isSafariBrowser() || isStandalonePwa()) return;
  if (safeStorage.get(INSTALL_HINT_DISMISSED_KEY) === "true") return;
  if (document.getElementById("ios-install-hint")) return;

  const hint = document.createElement("aside");
  hint.id = "ios-install-hint";
  hint.className =
    "fixed inset-x-4 bottom-4 z-[9998] rounded-lg border border-border bg-surface/95 p-4 shadow-2xl backdrop-blur safe-area-bottom";

  const row = document.createElement("div");
  row.className = "flex items-start gap-3";

  const icon = document.createElement("div");
  icon.className =
    "grid h-10 w-10 shrink-0 place-items-center rounded-lg bg-brand text-lg font-semibold text-white";
  icon.textContent = "S";

  const content = document.createElement("div");
  content.className = "min-w-0 flex-1";

  const title = document.createElement("p");
  title.className = "text-sm font-semibold text-text-primary";
  title.textContent = "Instale o Streamix";

  const copy = document.createElement("p");
  copy.className = "mt-1 text-xs leading-5 text-text-secondary";
  copy.textContent = "No Safari, toque em Compartilhar e depois em Adicionar à Tela de Início.";

  content.appendChild(title);
  content.appendChild(copy);

  const close = createIconButton("Fechar dica de instalação", "×");
  close.addEventListener("click", () => {
    safeStorage.set(INSTALL_HINT_DISMISSED_KEY, "true");
    hint.remove();
  });

  row.appendChild(icon);
  row.appendChild(content);
  row.appendChild(close);
  hint.appendChild(row);
  document.body.appendChild(hint);
};

let connectionToastTimer = null;

const showConnectionToast = (state) => {
  const existing = document.getElementById("connection-toast");
  existing?.remove();
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

const parseExpectedCacheName = (source) => {
  const match = source?.match(/const CACHE_VERSION = ['"]([^'"]+)['"]/);
  return match ? `${STREAMIX_CACHE_PREFIX}${match[1]}` : null;
};

const fetchExpectedCacheName = async () => {
  const response = await fetch(`/sw.js?ts=${Date.now()}`, {
    cache: "no-store",
    headers: { "cache-control": "no-cache" },
  });
  if (!response.ok) return null;
  return parseExpectedCacheName(await response.text());
};

const streamixCacheNames = async () => {
  if (!("caches" in window)) return [];
  const names = await caches.keys();
  return names.filter((name) => name.startsWith(STREAMIX_CACHE_PREFIX));
};

const clearStreamixCaches = async () => {
  const names = await streamixCacheNames();
  await Promise.all(names.map((name) => caches.delete(name)));
  return names;
};

const repairPwaApp = async ({ reload = true } = {}) => {
  const deletedCaches = await clearStreamixCaches();
  const registration = await navigator.serviceWorker?.getRegistration("/");

  if (registration) {
    await registration.update();
    registration.waiting?.postMessage({ type: "SKIP_WAITING" });
  }

  if (reload) {
    window.setTimeout(() => window.location.reload(), 700);
  }

  return { deletedCaches, hasRegistration: Boolean(registration) };
};

window.StreamixPwa = {
  clearCaches: clearStreamixCaches,
  expectedCacheName: fetchExpectedCacheName,
  repairApp: repairPwaApp,
  streamixCacheNames,
};

const showPwaRepairToast = ({ expectedCache, caches: currentCaches }) => {
  if (!isStandalonePwa() || document.getElementById("pwa-repair-toast")) return;

  const toast = document.createElement("div");
  toast.id = "pwa-repair-toast";
  toast.className =
    "fixed inset-x-4 bottom-4 z-[9999] rounded-lg border border-warning/30 bg-surface/95 p-4 text-sm text-text-primary shadow-2xl backdrop-blur safe-area-bottom";

  const title = document.createElement("p");
  title.className = "font-semibold text-text-primary";
  title.textContent = "Atualização disponível";

  const copy = document.createElement("p");
  copy.className = "mt-1 text-xs leading-5 text-text-secondary";
  copy.textContent = `Seu app está usando ${currentCaches.join(", ") || "cache antigo"}; versão esperada ${expectedCache}.`;

  const actions = document.createElement("div");
  actions.className = "mt-3 flex gap-2";

  const update = document.createElement("button");
  update.type = "button";
  update.className = "rounded-md bg-brand px-3 py-2 text-xs font-medium text-white";
  update.textContent = "Atualizar app";
  update.addEventListener("click", async () => {
    update.disabled = true;
    update.textContent = "Atualizando...";
    await repairPwaApp();
  });

  const dismiss = createIconButton("Fechar aviso de atualização", "Agora não");
  dismiss.addEventListener("click", () => toast.remove());

  actions.appendChild(update);
  actions.appendChild(dismiss);
  toast.appendChild(title);
  toast.appendChild(copy);
  toast.appendChild(actions);
  document.body.appendChild(toast);
};

const checkPwaCacheFreshness = async () => {
  if (!isStandalonePwa() || !("caches" in window) || !("serviceWorker" in navigator)) return;

  try {
    const [expectedCache, currentCaches] = await Promise.all([
      fetchExpectedCacheName(),
      streamixCacheNames(),
    ]);
    if (!expectedCache || currentCaches.length === 0) return;
    if (!currentCaches.includes(expectedCache) || currentCaches.length > 1) {
      showPwaRepairToast({ expectedCache, caches: currentCaches });
    }
  } catch (_error) {}
};

restoreLastPwaRoute();
window.addEventListener("pageshow", rememberCurrentRoute);
window.addEventListener("popstate", rememberCurrentRoute);
window.addEventListener("phx:page-loading-stop", () => window.setTimeout(rememberCurrentRoute, 0));
window.addEventListener("load", () => window.setTimeout(showIosInstallHint, 1200));
window.addEventListener("offline", () => showConnectionToast("offline"));
window.addEventListener("online", () => {
  showConnectionToast("online");
  if (!liveSocket.isConnected()) liveSocket.socket.connect();
});

// Merge colocated hooks with custom hooks
const Hooks = {
  ...colocatedHooks,
  ...customHooks,
};

const liveSocket = new LiveSocket("/live", Socket, {
  // Increase timeout to allow WebSocket through Cloudflare Tunnel
  // Default 2500ms is too short for tunneled connections
  longPollFallbackMs: 10000,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// Show progress bar on live navigation and form submits
const themeColor = (name, fallback) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
};

topbar.config({
  barColors: {
    0: themeColor("--brand-color", "#e50914"),
    0.65: themeColor("--brand-hover-color", "#f6121d"),
    1: themeColor("--accent-color", "#46d369"),
  },
  shadowColor: "rgba(229, 9, 20, .35)",
});
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// Safari iOS suspends WebSockets when the page is backgrounded (lock, tab
// switch, app switcher). When the page returns from the bfcache or the tab
// regains focus, force a reconnect so LiveView sessions resume without the
// "Something went wrong" flash + full refresh cycle. See
// https://github.com/phoenixframework/phoenix_live_view/issues/3236
window.addEventListener("pageshow", (event) => {
  if (event.persisted) liveSocket.socket.connect();
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !liveSocket.isConnected()) {
    liveSocket.socket.connect();
  }
});

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// View Transitions API for smooth LiveView navigation
if (document.startViewTransition) {
  document.addEventListener("phx:page-loading-start", (info) => {
    if (info.detail?.kind === "redirect") {
      document.startViewTransition();
    }
  });
}

// Register Service Worker for PWA with update notification
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    // Ask the browser to make storage persistent so Safari iOS is less
    // aggressive about wiping our cache and IndexedDB after 7 days of
    // inactivity. Silent no-op on Safari; Chromium honors it.
    if (navigator.storage?.persist) {
      navigator.storage.persist().catch(() => {});
    }

    navigator.serviceWorker
      .register("/sw.js")
      .then((reg) => {
        if (getEnvInfo().isDev) {
          console.log("SW registered:", reg.scope);
        }

        // Check for updates periodically (every 30 minutes)
        setInterval(() => reg.update(), 30 * 60 * 1000);

        // Listen for new SW waiting
        reg.addEventListener("updatefound", () => {
          const newWorker = reg.installing;
          if (newWorker) {
            newWorker.addEventListener("statechange", () => {
              if (newWorker.state === "installed" && navigator.serviceWorker.controller) {
                // New SW is waiting - show update toast
                showUpdateToast(newWorker);
              }
            });
          }
        });

        // Also check if there's already a waiting SW
        if (reg.waiting) {
          showUpdateToast(reg.waiting);
        }

        checkPwaCacheFreshness();
      })
      .catch((err) => console.warn("SW registration failed:", err));

    // Reload when controller changes (new SW took over)
    let refreshing = false;
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (refreshing) return;
      refreshing = true;
      window.location.reload();
    });
  });
}

// Show update toast notification (XSS-safe DOM construction)
function showUpdateToast(waitingWorker) {
  // Check if toast already exists
  if (document.getElementById("sw-update-toast")) return;

  const toast = document.createElement("div");
  toast.id = "sw-update-toast";
  toast.className =
    "fixed bottom-4 right-4 z-[9999] flex max-w-[calc(100vw-2rem)] items-center gap-3 px-4 py-3 bg-surface border border-border rounded-lg shadow-2xl animate-in slide-in-from-bottom-4 fade-in duration-300";

  // Content wrapper
  const content = document.createElement("div");
  content.className = "flex-1";

  const title = document.createElement("p");
  title.className = "text-sm font-medium text-text-primary";
  title.textContent = "Nova versão disponível";

  const subtitle = document.createElement("p");
  subtitle.className = "text-xs text-text-secondary";
  subtitle.textContent = "Clique para atualizar";

  content.appendChild(title);
  content.appendChild(subtitle);

  // Update button
  const updateBtn = document.createElement("button");
  updateBtn.className =
    "px-3 py-1.5 bg-brand text-white text-sm font-medium rounded-md hover:bg-brand-hover transition-colors";
  updateBtn.textContent = "Atualizar";
  updateBtn.addEventListener("click", () => {
    waitingWorker.postMessage({ type: "SKIP_WAITING" });
    toast.remove();
  });

  // Dismiss button with SVG
  const dismissBtn = document.createElement("button");
  dismissBtn.className = "p-1 text-text-secondary hover:text-text-primary transition-colors";
  dismissBtn.setAttribute("aria-label", "Fechar");

  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "w-4 h-4");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("viewBox", "0 0 24 24");

  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  path.setAttribute("stroke-width", "2");
  path.setAttribute("d", "M6 18L18 6M6 6l12 12");

  svg.appendChild(path);
  dismissBtn.appendChild(svg);
  dismissBtn.addEventListener("click", () => toast.remove());

  // Assemble toast
  toast.appendChild(content);
  toast.appendChild(updateBtn);
  toast.appendChild(dismissBtn);

  document.body.appendChild(toast);
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs();

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown;
    window.addEventListener("keydown", (e) => {
      keyDown = e.key;
    });
    window.addEventListener("keyup", () => {
      keyDown = null;
    });
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtCaller(e.target);
        } else if (keyDown === "d") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtDef(e.target);
        }
      },
      true,
    );

    window.liveReloader = reloader;
  });
}
