import { getEnvInfo } from "../core/logger";
import { checkPwaCacheFreshness } from "./cache_management";
import { createControllerChangeGuard } from "./service_worker_runtime";

const showUpdateToast = (waitingWorker) => {
  if (document.getElementById("sw-update-toast")) return;

  const toast = document.createElement("div");
  toast.id = "sw-update-toast";
  toast.className =
    "fixed bottom-4 right-4 z-[9999] flex max-w-[calc(100vw-2rem)] items-center gap-3 px-4 py-3 bg-surface border border-border rounded-lg shadow-2xl animate-in slide-in-from-bottom-4 fade-in duration-300";

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

  const updateButton = document.createElement("button");
  updateButton.className =
    "min-h-11 rounded-md bg-brand px-3 py-1.5 text-sm font-medium text-white transition-colors hover:bg-brand-hover";
  updateButton.textContent = "Atualizar";
  updateButton.addEventListener("click", () => {
    waitingWorker.postMessage({ type: "SKIP_WAITING" });
    toast.remove();
  });

  const dismissButton = document.createElement("button");
  dismissButton.className =
    "flex size-11 items-center justify-center text-text-secondary transition-colors hover:text-text-primary";
  dismissButton.setAttribute("aria-label", "Fechar");

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
  dismissButton.appendChild(svg);
  dismissButton.addEventListener("click", () => toast.remove());

  toast.appendChild(content);
  toast.appendChild(updateButton);
  toast.appendChild(dismissButton);
  document.body.appendChild(toast);
};

const watchForUpdates = (registration) => {
  registration.addEventListener("updatefound", () => {
    const newWorker = registration.installing;
    if (!newWorker) return;

    newWorker.addEventListener("statechange", () => {
      if (newWorker.state === "installed" && navigator.serviceWorker.controller) {
        showUpdateToast(newWorker);
      }
    });
  });

  if (registration.waiting) showUpdateToast(registration.waiting);
};

const bindControllerChange = () => {
  if (window.__swControllerChangeBound) return;

  window.__swControllerChangeBound = true;
  let refreshing = false;
  const shouldReload = createControllerChangeGuard(navigator.serviceWorker.controller);

  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (!shouldReload(navigator.serviceWorker.controller) || refreshing) return;
    refreshing = true;
    window.location.reload();
  });
};

export function registerServiceWorker({ isStandalonePwa }) {
  if (!("serviceWorker" in navigator)) return;

  window.addEventListener("load", () => {
    // Persistent storage reduces cache eviction in long-lived installed apps.
    navigator.storage?.persist?.().catch(() => {});

    navigator.serviceWorker
      .register("/sw.js")
      .then((registration) => {
        if (getEnvInfo().isDev) console.log("SW registered:", registration.scope);

        if (!window.__swUpdateInterval) {
          window.__swUpdateInterval = setInterval(() => registration.update(), 30 * 60 * 1000);
        }

        watchForUpdates(registration);
        checkPwaCacheFreshness(isStandalonePwa);
      })
      .catch((error) => console.warn("SW registration failed:", error));

    bindControllerChange();
  });
}
