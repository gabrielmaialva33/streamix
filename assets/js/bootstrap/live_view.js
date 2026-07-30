import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/streamix";
import topbar from "../../vendor/topbar";
import customHooks from "../hooks";

const themeColor = (name, fallback) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
};

const installTopbar = () => {
  topbar.config({
    barColors: {
      0: themeColor("--brand-color", "#e50914"),
      0.65: themeColor("--brand-hover-color", "#f6121d"),
      1: themeColor("--accent-color", "#46d369"),
    },
    shadowColor: "rgba(229, 9, 20, .35)",
  });
  window.addEventListener("phx:page-loading-start", () => topbar.show(300));
  window.addEventListener("phx:page-loading-stop", () => topbar.hide());
};

const installReconnectHandlers = (liveSocket) => {
  // Safari iOS suspends WebSockets while backgrounded or in the bfcache.
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) liveSocket.socket.connect();
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !liveSocket.isConnected()) {
      liveSocket.socket.connect();
    }
  });
};

const installViewTransitions = () => {
  if (!document.startViewTransition) return;

  document.addEventListener("phx:page-loading-start", (info) => {
    if (info.detail?.kind !== "redirect") return;

    // Rapid navigation aborts the pending transition. Consume both promises
    // so an expected AbortError does not pollute the console.
    const transition = document.startViewTransition();
    transition.ready.catch(() => {});
    transition.finished.catch(() => {});
  });
};

const installLiveReload = () => {
  if (process.env.NODE_ENV !== "development") return;

  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs();

    let keyDown;
    window.addEventListener("keydown", (event) => {
      keyDown = event.key;
    });
    window.addEventListener("keyup", () => {
      keyDown = null;
    });
    window.addEventListener(
      "click",
      (event) => {
        if (keyDown === "c") {
          event.preventDefault();
          event.stopImmediatePropagation();
          reloader.openEditorAtCaller(event.target);
        } else if (keyDown === "d") {
          event.preventDefault();
          event.stopImmediatePropagation();
          reloader.openEditorAtDef(event.target);
        }
      },
      true,
    );

    window.liveReloader = reloader;
  });
};

export function startLiveView() {
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const liveSocket = new LiveSocket("/live", Socket, {
    // A failed iOS WebSocket handshake must not pin the session to longpoll.
    longPollFallbackMs: null,
    params: { _csrf_token: csrfToken },
    hooks: {
      ...colocatedHooks,
      ...customHooks,
    },
  });

  installTopbar();
  liveSocket.connect();
  installReconnectHandlers(liveSocket);
  installViewTransitions();
  installLiveReload();

  // Public debug surface used by Phoenix's console helpers.
  window.liveSocket = liveSocket;
  return liveSocket;
}
