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

window.Alpine = Alpine;
Alpine.start();

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/streamix";
import topbar from "../vendor/topbar";
import customHooks from "./hooks";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

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
topbar.config({ barColors: { 0: "#64cc95" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

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
    navigator.serviceWorker
      .register("/sw.js")
      .then((reg) => {
        console.log("SW registered:", reg.scope);

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
    "fixed bottom-4 right-4 z-[9999] flex items-center gap-3 px-4 py-3 bg-surface border border-border rounded-lg shadow-2xl animate-in slide-in-from-bottom-4 fade-in duration-300";

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
