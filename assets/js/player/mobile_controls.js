import { LifecycleScope } from "./lifecycle_scope.js";
import { nextTapGesture, pinchFit } from "./player_gestures.js";

const INTERACTIVE_SELECTOR =
  "button, a, input, select, textarea, label, [role='button'], [role='slider'], #progress-container, #speed-menu, #settings-menu, #tracks-menu";

export function isPlayerBackgroundTarget(target, ElementImpl = globalThis.Element) {
  return typeof ElementImpl === "function" && target instanceof ElementImpl
    ? !target.closest(INTERACTIVE_SELECTOR)
    : false;
}

const distance = (touches) =>
  Math.hypot(touches[0].clientX - touches[1].clientX, touches[0].clientY - touches[1].clientY);

export function createMobileControls({
  root,
  controls,
  video,
  presentation,
  shouldUseNativeControls,
  seek,
  togglePlayPause,
  getContentType,
  environment = {
    window: globalThis.window,
    navigator: globalThis.navigator,
    Element: globalThis.Element,
  },
  now = Date.now,
  scheduler = globalThis,
}) {
  if (!root || !controls || !video) return { destroy() {} };
  const lifecycle = new LifecycleScope();
  let lastTap = null;
  let singleTapTimer = null;
  let initialPinchDistance = null;
  let pinching = false;
  let suppressClickUntil = -1;
  const isTouchDevice =
    "ontouchstart" in environment.window || environment.navigator.maxTouchPoints > 0;
  const locked = () => root.dataset.playerLocked !== undefined;
  const blocked = () => locked() || shouldUseNativeControls() || Boolean(root.dataset.playerPanel);
  const viewer = () => root.dataset.partyRole === "viewer";
  const cancelTap = () => {
    scheduler.clearTimeout(singleTapTimer);
    singleTapTimer = null;
  };
  const resetTap = () => {
    cancelTap();
    lastTap = null;
  };

  const onPlayerClick = (event) => {
    if (
      event.defaultPrevented ||
      blocked() ||
      now() <= suppressClickUntil ||
      !isPlayerBackgroundTarget(event.target, environment.Element)
    ) {
      resetTap();
      return;
    }
    const { left, width } = root.getBoundingClientRect();
    if (!(width > 0)) return;
    event.preventDefault();
    const tap = nextTapGesture(lastTap, (event.clientX - left) / width, now());
    cancelTap();
    lastTap = tap;
    if (tap.action) {
      if (tap.action === "toggle-play") {
        lastTap = null;
        if (!viewer()) togglePlayPause();
      } else if (!viewer() && getContentType() !== "live") {
        seek(tap.action === "seek-backward" ? -10 : 10);
      }
    } else if (!presentation.controlsVisible) {
      // Like Netflix and YouTube, the first tap shows the controls at once; a
      // second tap inside the window still seeks. Only hiding waits, so a
      // double tap never flickers the controls away.
      presentation.revealControls();
    } else {
      singleTapTimer = scheduler.setTimeout(() => {
        singleTapTimer = null;
        if (!blocked()) presentation.toggleControlsVisibility();
      }, 300);
    }
  };
  const onTouchStart = (event) => {
    if (blocked() || !isPlayerBackgroundTarget(event.target, environment.Element)) {
      resetTap();
      pinching = false;
      initialPinchDistance = null;
      return;
    }
    if (event.touches.length !== 2) return;
    resetTap();
    pinching = true;
    initialPinchDistance = distance(event.touches);
    presentation.cancelControlsAutoHide();
  };
  const onTouchMove = (event) => {
    if (blocked() || !pinching || event.touches.length !== 2) return;
    event.preventDefault();
    const fit = pinchFit(initialPinchDistance, distance(event.touches));
    if (fit === "fill") root.dataset.playerFit = "fill";
    else if (fit === "fit") delete root.dataset.playerFit;
  };
  const onTouchEnd = (event) => {
    if (!pinching) return;
    suppressClickUntil = now() + 700;
    if (event.touches.length === 0) {
      pinching = false;
      initialPinchDistance = null;
      if (!locked()) presentation.scheduleControlsAutoHide();
    }
  };
  const onMouseMove = () => {
    if (!isTouchDevice && !locked()) presentation.revealControls();
  };
  if (isTouchDevice) {
    lifecycle.listen(root, "click", onPlayerClick);
    lifecycle.listen(root, "touchstart", onTouchStart, { passive: true });
    lifecycle.listen(root, "touchmove", onTouchMove, { passive: false });
    lifecycle.listen(root, "touchend", onTouchEnd, { passive: true });
    lifecycle.listen(
      root,
      "touchcancel",
      (event) => {
        resetTap();
        onTouchEnd(event);
      },
      { passive: true },
    );
    lifecycle.listen(
      controls,
      "touchstart",
      () => {
        if (!locked()) presentation.cancelControlsAutoHide();
      },
      { passive: true },
    );
    lifecycle.listen(
      controls,
      "touchend",
      () => {
        if (!locked()) presentation.scheduleControlsAutoHide();
      },
      { passive: true },
    );
    presentation.revealControls();
  }
  lifecycle.listen(root, "mousemove", onMouseMove);
  lifecycle.listen(video, "play", () => presentation.scheduleControlsAutoHide());
  lifecycle.listen(video, "pause", () => presentation.keepControlsVisible());
  return {
    destroy() {
      lifecycle.dispose();
      resetTap();
    },
  };
}
