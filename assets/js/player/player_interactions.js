import { createFocusTrap } from "../core/focus_trap.js";
import { LifecycleScope } from "./lifecycle_scope.js";
import { PLAYBACK_BRIDGE_EVENT } from "./playback_bridge.js";
import { canShowIdlePause } from "./player_gestures.js";

const OVERLAYS = [
  "#error-container",
  "#ended-overlay",
  "#speed-menu",
  "#settings-menu",
  "#tracks-menu",
  "#autoplay-overlay",
  "#next-episode-overlay",
];

function visible(element) {
  if (!element || element.hidden || element.classList.contains("hidden")) return false;
  const style = element.ownerDocument?.defaultView?.getComputedStyle(element) || element.style;
  return style?.display !== "none" && style?.visibility !== "hidden";
}

export function createPlayerInteractions({
  root,
  video,
  isPaused,
  getContentType,
  seek,
  togglePlayPause,
  nextEpisode,
  documentRef = globalThis.document,
  scheduler = globalThis,
  now = Date.now,
  MutationObserverImpl = globalThis.MutationObserver,
}) {
  const lifecycle = new LifecycleScope();
  const bubbles = new Map();
  let idleTimer = null;
  let feedbackTimer = null;
  let lastFeedback = null;
  let destroyed = false;
  const locked = () => root.dataset.playerLocked !== undefined;
  const viewer = () => root.dataset.partyRole === "viewer";
  const transportAllowed = () => !locked() && !viewer();

  const episodesPanel = root.querySelector("#player-episodes-panel");
  const episodesLayer = root.querySelector("#player-episodes-layer");
  let backgroundInert = [];
  const closeEpisodes = () => {
    delete root.dataset.playerPanel;
    for (const [element, inert] of backgroundInert) element.inert = inert;
    backgroundInert = [];
    episodesFocus?.deactivate();
  };
  const episodesFocus = episodesPanel
    ? createFocusTrap(episodesPanel, {
        documentRef,
        scheduler,
        returnFocusTo: root.querySelector("#player-episodes-btn"),
        closeOnClickOutside: false,
        onEscape: closeEpisodes,
      })
    : null;
  const openEpisodes = () => {
    root.dataset.playerPanel = "episodes";
    if (!episodesFocus || episodesFocus.isActive()) return;
    backgroundInert = Array.from(root.children)
      .filter((element) => element !== episodesLayer)
      .map((element) => [element, element.inert]);
    for (const [element] of backgroundInert) element.inert = true;
    episodesFocus.activate();
  };
  lifecycle.add(closeEpisodes);

  const clearIdle = () => {
    scheduler.clearTimeout(idleTimer);
    idleTimer = null;
    delete root.dataset.playerIdlePaused;
  };
  const eligible = () =>
    canShowIdlePause({
      paused: isPaused(),
      live: getContentType() === "live",
      viewer: viewer(),
      blocked:
        locked() ||
        Boolean(root.dataset.playerPanel) ||
        OVERLAYS.some((id) => visible(root.querySelector(id))),
      ended: Boolean(video?.ended),
    });
  let wasEligible = eligible();
  const activity = () => {
    clearIdle();
    wasEligible = eligible();
    if (!wasEligible || destroyed) return;
    idleTimer = scheduler.setTimeout(() => {
      idleTimer = null;
      if (eligible() && !destroyed) root.dataset.playerIdlePaused = "true";
    }, 6000);
  };
  const syncState = () => {
    if (
      episodesFocus?.isActive() &&
      (root.dataset.playerPanel !== "episodes" || locked() || viewer())
    ) {
      closeEpisodes();
    }
    const allowed = eligible();
    if (!allowed) clearIdle();
    else if (!wasEligible) activity();
    wasEligible = allowed;
  };

  const showSeekFeedback = (seconds) => {
    const side = seconds < 0 ? "left" : "right";
    const time = now();
    const amount =
      lastFeedback?.side === side && time - lastFeedback.time <= 700
        ? lastFeedback.amount + Math.abs(seconds)
        : Math.abs(seconds);
    lastFeedback = { side, time, amount };
    for (const bubble of bubbles.values()) bubble.dataset.visible = "false";
    let bubble = bubbles.get(side);
    if (!bubble) {
      bubble = root.ownerDocument.createElement("div");
      bubble.className = "player-seek-feedback";
      bubble.dataset.side = side;
      bubble.setAttribute("aria-hidden", "true");
      const label = root.ownerDocument.createElement("span");
      label.className = "player-seek-feedback-label";
      bubble.appendChild(label);
      root.appendChild(bubble);
      bubbles.set(side, bubble);
    }
    bubble.querySelector(".player-seek-feedback-label").textContent =
      `${seconds < 0 ? "−" : "+"}${amount} s`;
    bubble.dataset.visible = "true";
    scheduler.clearTimeout(feedbackTimer);
    feedbackTimer = scheduler.setTimeout(() => {
      feedbackTimer = null;
      bubble.dataset.visible = "false";
    }, 700);
  };
  const seekBy = (seconds) => {
    if (destroyed || !transportAllowed() || getContentType() === "live") return false;
    if (seek(seconds) === false) return false;
    showSeekFeedback(seconds);
    return true;
  };
  const onClick = (event) => {
    const button = event.target?.closest?.("[data-player-action]");
    const action = button && root.contains(button) ? button.dataset.playerAction : null;
    if (locked() && action !== "unlock") {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    if (!action || button.disabled || button.getAttribute("aria-disabled") === "true") return;
    const handlers = {
      "seek-backward": () => seekBy(-10),
      "seek-forward": () => seekBy(10),
      "toggle-play": () => transportAllowed() && togglePlayPause(),
      "next-episode": () => transportAllowed() && nextEpisode?.(),
      episodes: () => {
        if (!transportAllowed()) return;
        if (root.dataset.playerPanel === "episodes") closeEpisodes();
        else openEpisodes();
      },
      "close-panel": closeEpisodes,
      lock: () => {
        root.dataset.playerLocked = "true";
        closeEpisodes();
      },
      unlock: () => {
        delete root.dataset.playerLocked;
      },
      "fit-toggle": () => {
        if (root.dataset.playerFit === "fill") delete root.dataset.playerFit;
        else root.dataset.playerFit = "fill";
      },
    };
    if (!Object.hasOwn(handlers, action)) return;
    event.preventDefault();
    // Own the action even when this is also an existing id/onclick button.
    event.stopImmediatePropagation();
    handlers[action]();
    activity();
  };

  lifecycle.listen(root, "click", onClick, { capture: true });
  for (const event of ["pointermove", "pointerdown", "touchstart", "touchmove", "click"]) {
    lifecycle.listen(root, event, activity, { passive: true, capture: true });
  }
  lifecycle.listenOptional(documentRef, "keydown", activity, { capture: true });
  for (const event of ["play", "pause", "ended"]) lifecycle.listenOptional(video, event, activity);
  lifecycle.listen(root, PLAYBACK_BRIDGE_EVENT, activity);
  if (MutationObserverImpl) {
    const observer = new MutationObserverImpl(syncState);
    observer.observe(root, {
      attributes: true,
      subtree: true,
      attributeFilter: [
        "class",
        "style",
        "hidden",
        "data-player-panel",
        "data-player-locked",
        "data-party-role",
      ],
    });
    lifecycle.add(() => observer.disconnect());
  }
  activity();

  return {
    seekBy,
    destroy() {
      destroyed = true;
      lifecycle.dispose();
      clearIdle();
      scheduler.clearTimeout(feedbackTimer);
      for (const bubble of bubbles.values()) bubble.remove();
      bubbles.clear();
    },
  };
}
